import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart'
    show ValueNotifier, visibleForTesting, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

class CalendarState {
  final DateTime displayedMonth; // 顶栏显示的年月
  final DateTime selectedDay; // 选中的日期
  final String view; // month / week / day
  final List<CalendarItem> items; // 当前加载的日历条目
  /// 丝滑翻页：按天索引的日历条目（key = yyyymmdd 整数），
  /// 视图层据此 O(1) 取当天数据（此前每页 build 全窗口扫描）
  final Map<int, List<CalendarItem>> byDay;
  final bool loading;

  const CalendarState({
    required this.displayedMonth,
    required this.selectedDay,
    this.view = 'week',
    this.items = const [],
    this.byDay = const {},
    this.loading = true,
  });

  CalendarState copyWith({
    DateTime? displayedMonth,
    DateTime? selectedDay,
    String? view,
    List<CalendarItem>? items,
    Map<int, List<CalendarItem>>? byDay,
    bool? loading,
  }) => CalendarState(
    displayedMonth: displayedMonth ?? this.displayedMonth,
    selectedDay: selectedDay ?? this.selectedDay,
    view: view ?? this.view,
    items: items ?? this.items,
    byDay: byDay ?? this.byDay,
    loading: loading ?? this.loading,
  );
}

class CalendarController extends StateNotifier<CalendarState> {
  CalendarController(this._db, this._scheduler, this._ref)
    : super(
        CalendarState(
          displayedMonth: DateTime(
            AppClock.now().year,
            AppClock.now().month,
            1,
          ),
          selectedDay: AppClock.now(),
        ),
      ) {
    // I3：#23 实时同步——数据版本变化自动刷新（缓存失效重拉）
    _ref.listen<int>(dataVersionProvider, (prev, next) {
      if (prev != next) {
        _invalidateCache();
        load(force: true);
      }
    });
    load();
  }

  /// 周↔日视图共享的垂直滚动位置（切换视图时保持位置连续，不跳回顶部）
  final ValueNotifier<double> globalScrollOffset = ValueNotifier<double>(0);

  final AppDatabase _db;
  final ReminderScheduler _scheduler;
  final Ref _ref;

  /// 数据变更后通知任务页/统计/四象限自动刷新
  void _bump() {
    _ref.read(dataVersionProvider.notifier).state++;
  }

  /// 当前展示范围（月视图=整月；周视图=周一至周日）
  (DateTime, DateTime) get _range {
    final state = this.state;
    switch (state.view) {
      case 'month':
        final first = AppClock.at(
          state.displayedMonth.year,
          state.displayedMonth.month,
          1,
        );
        final last = AppClock.at(
          state.displayedMonth.year,
          state.displayedMonth.month + 1,
          0,
        );
        return (first, last);
      case 'week':
        final monday = AppClock.at(
          state.selectedDay.year,
          state.selectedDay.month,
          state.selectedDay.day,
        ).subtract(Duration(days: state.selectedDay.weekday - 1));
        return (monday, monday.add(const Duration(days: 6)));
      case 'day':
        final d = AppClock.at(
          state.selectedDay.year,
          state.selectedDay.month,
          state.selectedDay.day,
        );
        return (d, d);
    }
    return (AppClock.now(), AppClock.now());
  }

  /// 加载请求序号：快速翻页/切换时丢弃过期结果，避免旧数据覆盖新数据
  int _loadSeq = 0;

  /// 是否已完成首次加载（仅首载置 loading 显示 spinner）。
  /// 此前用 `items.isEmpty` 判断——空数据周/天（该周无任务，items 为空）
  /// 会被误判为"未加载"，下次未命中翻页时置 loading:true 挂起 → 真机上
  /// spinner 整页替换 → WeekView State 销毁 → 拖拽状态全灭（仅周视图
  /// 翻到缓存边界时复现）
  bool _loadedOnce = false;

  // ---------- 丝滑翻页：窗口缓存（翻页/切视图命中缓存 = 零 DB） ----------

  /// 按天缓存：key = yyyymmdd 整数
  final Map<int, List<CalendarItem>> _cache = {};

  /// 缓存覆盖的天区间（闭区间，dayKey 整数）；null = 无缓存
  int? _cacheFromKey;
  int? _cacheToKey;

  /// 测试用：实际 DB 查询次数（翻页命中缓存不增加）
  @visibleForTesting
  int loadCount = 0;

  static int _dayKey(DateTime d) {
    final a = AppClock.asApp(d);
    return a.year * 10000 + a.month * 100 + a.day;
  }

  static Map<int, List<CalendarItem>> _byDayFor(List<CalendarItem> items) {
    final map = <int, List<CalendarItem>>{};
    for (final it in items) {
      map.putIfAbsent(_dayKey(it.instanceDate), () => []).add(it);
    }
    return map;
  }

  bool _cacheCovers(DateTime from, DateTime to) {
    final f = _cacheFromKey;
    final t = _cacheToKey;
    return f != null && t != null && _dayKey(from) >= f && _dayKey(to) <= t;
  }

  /// 缓存失效（数据版本变化/写操作后调用）：
  /// 清空按天缓存与覆盖区间，下次 load 强制重查
  void _invalidateCache() {
    _cache.clear();
    _cacheFromKey = null;
    _cacheToKey = null;
  }

  /// 从缓存取出 [from, to] 范围内的条目（按天升序）
  List<CalendarItem> _itemsInRange(DateTime from, DateTime to) {
    final f = _dayKey(from);
    final t = _dayKey(to);
    final result = <CalendarItem>[];
    for (final entry in _cache.entries) {
      if (entry.key >= f && entry.key <= t) {
        result.addAll(entry.value);
      }
    }
    return result;
  }

  /// 加载/确保当前视图范围数据。
  /// - 命中缓存（含 31 天扩展缓冲）→ 同步出数据，零 DB、无异步二次重建
  /// - 未命中 → 查询 [范围 ± 31 天] 重建缓存（替换式，保证一致性）
  /// [force]：数据版本变化/写操作后强制重查
  Future<void> load({bool force = false}) async {
    final seq = ++_loadSeq;
    final (from, to) = _range;
    // 仅首次加载置 loading——翻页/切视图的重复 load 不再触发 loading:true
    // （items 两次状态变更每次 ref.watch 全页重建）。空数据周翻页也不得
    // 误置（否则真机异步查库挂起时 spinner 整页替换销毁 WeekView State）
    if (!_loadedOnce && !force) {
      _loadedOnce = true;
      state = state.copyWith(loading: true);
    }
    // 命中缓存（且未强制）：直接从缓存出数据，零 DB
    if (!force && _cacheCovers(from, to)) {
      final items = _itemsInRange(from, to);
      state = state.copyWith(
        items: items,
        byDay: _byDayFor(items),
        loading: false,
      );
      return;
    }
    loadCount++;
    // 扩展缓冲：月视图 ±1 月、周/日视图覆盖前后多周/多日，
    // 连续翻页在手势动画内零 DB。±45 天（约 6 周）把连续边缘翻页的
    // 缓存未命中点推迟到第 6/12 页附近，降低拖拽中异步重建的 jank
    final bufFrom = from.subtract(const Duration(days: 45));
    final bufTo = to.add(const Duration(days: 45));
    try {
      final fetched = await _db.getCalendarItems(bufFrom, bufTo);
      if (!mounted || seq != _loadSeq) return; // 过期请求结果丢弃
      _cache
        ..clear()
        ..addAll(_byDayFor(fetched));
      _cacheFromKey = _dayKey(bufFrom);
      _cacheToKey = _dayKey(bufTo);
      final items = _itemsInRange(from, to);
      state = state.copyWith(
        items: items,
        byDay: _byDayFor(items),
        loading: false,
      );
    } catch (e) {
      // 查询失败不崩溃（构造器 fire-and-forget 路径无兜底时异常为
      // unhandled async error）；恢复 loading 避免 UI 卡在加载态
      debugPrint('日历加载失败: $e');
      if (seq == _loadSeq) {
        state = state.copyWith(loading: false);
      }
    }
  }

  void setView(String view) {
    if (state.view == view) return;
    state = state.copyWith(view: view);
    load();
  }

  /// E9/E11：月视图翻页时更新显示月份
  void setDisplayedMonth(DateTime month) {
    state = state.copyWith(
      displayedMonth: AppClock.at(month.year, month.month, 1),
      selectedDay: AppClock.at(
        month.year,
        month.month,
        state.selectedDay.day.clamp(1, DateUtilsEx.daysInMonth(month)),
      ),
    );
    load();
  }

  void setSelectedDay(DateTime day) {
    state = state.copyWith(
      selectedDay: day,
      displayedMonth: AppClock.at(day.year, day.month, 1),
    );
    load();
  }

  /// 选中日期 + 切换视图合并为一次 load
  /// （周视图头部点击"跳日视图"此前触发两次 load）
  void setSelectedDayWithView(DateTime day, String view) {
    state = state.copyWith(
      selectedDay: day,
      displayedMonth: AppClock.at(day.year, day.month, 1),
      view: view,
    );
    load();
  }

  void goToToday() {
    final now = AppClock.now();
    state = state.copyWith(
      displayedMonth: AppClock.at(now.year, now.month, 1),
      selectedDay: now,
    );
    load();
  }

  /// 拖动改期到具体时刻（含时分，支持跨天；拖进时间轴即非全天）
  Future<void> moveTaskToDateTime(int taskId, DateTime target) async {
    try {
      await _moveTaskToDateTimeInner(taskId, target);
    } catch (e) {
      debugPrint('日历改期失败 taskId=$taskId: $e');
    }
  }

  Future<void> _moveTaskToDateTimeInner(
    int taskId,
    DateTime target,
  ) async {
    final t = await _db.getTask(taskId);
    if (t == null) return;
    SoundService.instance.play(SoundKind.drop);
    Haptics.light();
    // 改期前先取消旧任务全部通知
    await _scheduler.cancelTask(taskId);
    final ps = t.planStart;
    final pe = t.planEnd;
    final dur = (pe != null && ps != null)
        ? pe.difference(ps)
        : const Duration(hours: 1);
    // C5-1：落点吸附"时长不跨天"约束——拖到 23:00 且时长跨过午夜时
    // 回退起点（此前 1 小时任务拖到 23:00 变跨天、跳进置顶区且无法拖回）
    // 与拖拽预览端（虚影/时间胶囊）统一用 clampStartWithinDay
    final start = DateUtilsEx.clampStartWithinDay(target, dur);
    await _db.updateTask(
      taskId,
      TasksCompanion(
        planStart: Value(start),
        planEnd: Value(start.add(dur)),
        isAllDay: const Value(false),
      ),
    );
    final updated = await _db.getTask(taskId);
    if (updated != null) {
      await _scheduler.scheduleTask(updated);
    }
    _bump();
    load();
  }

  // ---------- 重复任务：整个系列改期（拖动） ----------

  /// 系列改期撤销快照
  _SeriesReschedule? _seriesUndo;

  /// 重复任务拖动改期：整个系列（统一锚点吸附 + 清理完成记录与例外，可撤销）
  Future<void> moveTaskToDateTimeSeries(int taskId, DateTime target) async {
    try {
      await _moveTaskToDateTimeSeriesInner(taskId, target);
    } catch (e) {
      debugPrint('日历系列改期失败 taskId=$taskId: $e');
    }
  }

  Future<void> _moveTaskToDateTimeSeriesInner(
    int taskId,
    DateTime target,
  ) async {
    final t = await _db.getTask(taskId);
    if (t == null || t.rrule.isEmpty) return;
    SoundService.instance.play(SoundKind.drop);
    // 批4-3：拖拽改期强度统一为 light（此前单次 light/系列 medium 不一致）
    Haptics.light();
    // 系列改期前先取消旧规则全部通知
    await _scheduler.cancelTask(taskId);
    final oldStart = t.planStart;
    final oldEnd = t.planEnd;
    final dur = (oldEnd != null && oldStart != null)
        ? oldEnd.difference(oldStart)
        : const Duration(hours: 1);
    // C5-1：系列改期同样应用"时长不跨天"约束（与预览端统一）
    final clamped = DateUtilsEx.clampStartWithinDay(target, dur);
    // ：拖动目标日不命中规则时吸附到最近命中日——与任务创建/详情
    // 改规则同口径（否则锚点落在非命中日，系列在当前窗口"消失"）。
    // 先 clamp 再吸附日期部分（保留时分）：吸附只调整日期，
    // 避免对长时长任务先吸附后 clamp 又把起点推回非命中日。
    final anchorDay = AppClock.at(clamped.year, clamped.month, clamped.day);
    final hit = RruleService.instance.nearestHitOnOrNear(anchorDay, t.rrule);
    final start = hit == null
        ? clamped
        : AppClock.at(
            hit.year,
            hit.month,
            hit.day,
            clamped.hour,
            clamped.minute,
          );
    await _db.updateTask(
      taskId,
      TasksCompanion(
        planStart: Value(start),
        planEnd: Value(start.add(dur)),
        isAllDay: const Value(false),
      ),
    );
    // ：统一走 applyRecurringChange 收口——清理不再匹配新系列的
    // 完成记录与例外（此前仅 pruneCompletionsForTask，旧例外残留
    // 会让已改期实例与系列语义不一致）
    final removed = await _db.applyRecurringChange(
      taskId,
      oldRrule: t.rrule,
      newRrule: t.rrule,
      newStart: start,
    );
    _seriesUndo = _SeriesReschedule(
      taskId: taskId,
      oldStart: oldStart,
      oldEnd: oldEnd,
      oldIsAllDay: t.isAllDay,
      removedCompletions: removed.removedCompletions,
      removedExceptions: removed.removedExceptions,
    );
    final updated = await _db.getTask(taskId);
    if (updated != null) {
      await _scheduler.scheduleTask(updated);
    }
    _bump();
    load();
  }

  /// 撤销系列改期（恢复原计划时间 + 被清理的完成记录与例外）
  Future<void> undoMoveTaskSeries() async {
    try {
      await _undoMoveTaskSeriesInner();
    } catch (e) {
      debugPrint('撤销系列改期失败: $e');
    }
  }

  Future<void> _undoMoveTaskSeriesInner() async {
    final s = _seriesUndo;
    if (s == null) return;
    _seriesUndo = null;
    final t = await _db.getTask(s.taskId);
    if (t == null) return;
    await _db.updateTask(
      s.taskId,
      TasksCompanion(
        planStart: s.oldStart == null ? const Value(null) : Value(s.oldStart),
        planEnd: s.oldEnd == null ? const Value(null) : Value(s.oldEnd),
        // 撤销恢复全天状态——此前快照缺 isAllDay，全天系列
        // 拖动改期后撤销变成时段任务
        isAllDay: Value(s.oldIsAllDay),
      ),
    );
    for (final c in s.removedCompletions) {
      await _db.insertCompletionRaw(
        TaskCompletionsCompanion(
          id: Value(c.id),
          taskId: Value(c.taskId),
          instanceDate: Value(c.instanceDate),
          completedAt: Value(c.completedAt),
        ),
      );
    }
    // ：撤销同样恢复被清理的例外（此前快照不存例外，
    // 撤销后旧例外永久丢失，实例语义不一致）
    for (final e in s.removedExceptions) {
      await _db.insertExceptionRaw(
        TaskExceptionsCompanion(
          id: Value(e.id),
          taskId: Value(e.taskId),
          instanceDate: Value(e.instanceDate),
          action: Value(e.action),
          overrideScheduledDate: e.overrideScheduledDate == null
              ? const Value(null)
              : Value(e.overrideScheduledDate),
        ),
      );
    }
    final updated = await _db.getTask(s.taskId);
    if (updated != null) {
      await _scheduler.scheduleTask(updated);
    }
    _bump();
    load();
  }

  /// 任务完成/恢复（日历直接勾选）
  Future<void> toggleComplete(CalendarItem item) async {
    try {
      await _toggleCompleteInner(item);
    } catch (e) {
      debugPrint('日历完成/恢复失败 taskId=${item.task.id}: $e');
    }
  }

  Future<void> _toggleCompleteInner(CalendarItem item) async {
    if (item.completed) {
      if (item.task.rrule.isNotEmpty) {
        await _db.uncompleteInstance(item.task.id, item.instanceDate);
        // 恢复实例后重排：该实例提醒重新排上
        final fresh = await _db.getTask(item.task.id);
        if (fresh != null) {
          await _scheduler.scheduleTask(fresh);
        }
      } else {
        await _db.reopenTask(item.task.id);
      }
      SoundService.instance.play(SoundKind.reopen);
      Haptics.light();
    } else {
      if (item.task.rrule.isNotEmpty) {
        // 命中校验统一收口（日历条目本身来自规则展开，正常必命中；
        // 兜底防御未来新增入口绕过 UI 检查）
        await _db.completeInstanceIfHit(item.task.id, item.instanceDate);
        // 完成实例后重排：取消该实例已排提醒，其余未完成实例保留
        final fresh = await _db.getTask(item.task.id);
        if (fresh != null) {
          await _scheduler.scheduleTask(fresh);
        }
      } else {
        await _db.completeTask(item.task.id);
        await _scheduler.cancelTask(item.task.id);
      }
      SoundService.instance.play(SoundKind.complete);
      Haptics.medium();
    }
    _bump();
    load();
  }

  /// 跳过重复实例
  Future<void> skipInstance(int taskId, DateTime instanceDate) async {
    try {
      // 核心逻辑（暂存完成记录/容错/重排）统一在
      // ReminderScheduler（任务页与日历页共用），控制器只负责反馈与刷新
      final ok = await _scheduler.skipInstance(taskId, instanceDate);
      if (!ok) return;
      SoundService.instance.play(SoundKind.skip);
      Haptics.light();
      _bump();
      load();
    } catch (e) {
      debugPrint('跳过实例失败 taskId=$taskId: $e');
    }
  }

  /// 撤销跳过实例（从 skippedDates 移除日期，并恢复被删除的完成记录）
  Future<void> unskipInstance(int taskId, DateTime instanceDate) async {
    try {
      final ok = await _scheduler.unskipInstance(taskId, instanceDate);
      if (!ok) return;
      SoundService.instance.play(SoundKind.reopen);
      Haptics.light();
      _bump();
      load();
    } catch (e) {
      debugPrint('撤销跳过失败 taskId=$taskId: $e');
    }
  }
}

final calendarControllerProvider =
    StateNotifierProvider<CalendarController, CalendarState>((ref) {
      return CalendarController(
        ref.read(dbProvider),
        ref.read(reminderSchedulerProvider),
        ref,
      );
    });

/// 系列改期撤销快照（原计划时间 + 全天状态 + 被清理的完成记录与例外）
class _SeriesReschedule {
  final int taskId;
  final DateTime? oldStart;
  final DateTime? oldEnd;
  final bool oldIsAllDay;
  final List<TaskCompletion> removedCompletions;
  final List<TaskException> removedExceptions;

  _SeriesReschedule({
    required this.taskId,
    required this.oldStart,
    required this.oldEnd,
    required this.oldIsAllDay,
    required this.removedCompletions,
    this.removedExceptions = const [],
  });
}
