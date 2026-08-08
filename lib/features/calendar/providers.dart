import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';

class CalendarState {
  final DateTime displayedMonth; // 顶栏显示的年月
  final DateTime selectedDay; // 选中的日期
  final String view; // month / week / day
  final List<CalendarItem> items; // 当前加载的日历条目
  final bool loading;

  const CalendarState({
    required this.displayedMonth,
    required this.selectedDay,
    this.view = 'week',
    this.items = const [],
    this.loading = true,
  });

  CalendarState copyWith({
    DateTime? displayedMonth,
    DateTime? selectedDay,
    String? view,
    List<CalendarItem>? items,
    bool? loading,
  }) => CalendarState(
    displayedMonth: displayedMonth ?? this.displayedMonth,
    selectedDay: selectedDay ?? this.selectedDay,
    view: view ?? this.view,
    items: items ?? this.items,
    loading: loading ?? this.loading,
  );
}

class CalendarController extends StateNotifier<CalendarState> {
  CalendarController(this._db, this._scheduler, this._ref)
    : super(
        CalendarState(
          displayedMonth: DateTime(
            DateTime.now().year,
            DateTime.now().month,
            1,
          ),
          selectedDay: DateTime.now(),
        ),
      ) {
    // I3：#23 实时同步——数据版本变化自动刷新
    _ref.listen<int>(dataVersionProvider, (prev, next) {
      if (prev != next) {
        load();
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
        final first = DateTime(
          state.displayedMonth.year,
          state.displayedMonth.month,
          1,
        );
        final last = DateTime(
          state.displayedMonth.year,
          state.displayedMonth.month + 1,
          0,
        );
        return (first, last);
      case 'week':
        final monday = DateTime(
          state.selectedDay.year,
          state.selectedDay.month,
          state.selectedDay.day,
        ).subtract(Duration(days: state.selectedDay.weekday - 1));
        return (monday, monday.add(const Duration(days: 6)));
      case 'day':
        final d = DateTime(
          state.selectedDay.year,
          state.selectedDay.month,
          state.selectedDay.day,
        );
        return (d, d);
    }
    return (DateTime.now(), DateTime.now());
  }

  /// 加载请求序号：快速翻页/切换时丢弃过期结果，避免旧数据覆盖新数据
  int _loadSeq = 0;

  Future<void> load() async {
    final seq = ++_loadSeq;
    final (from, to) = _range;
    // A13：仅首次（items 为空）置 loading——翻页/切视图的重复 load 不再
    // 触发 loading:true → items 两次状态变更（每次 ref.watch 全页重建，
    // 中端机横滑翻页时明显卡顿）；日历页 spinner 本就只依赖首次空态
    if (state.items.isEmpty) {
      state = state.copyWith(loading: true);
    }
    final items = await _db.getCalendarItems(from, to);
    if (!mounted || seq != _loadSeq) return; // 过期请求结果丢弃
    state = state.copyWith(items: items, loading: false);
  }

  void setView(String view) {
    if (state.view == view) return;
    state = state.copyWith(view: view);
    load();
  }

  /// E9/E11：月视图翻页时更新显示月份
  void setDisplayedMonth(DateTime month) {
    state = state.copyWith(
      displayedMonth: DateTime(month.year, month.month, 1),
      selectedDay: DateTime(
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
      displayedMonth: DateTime(day.year, day.month, 1),
    );
    load();
  }

  /// P2：选中日期 + 切换视图合并为一次 load
  /// （周视图头部点击"跳日视图"此前触发两次 load）
  void setSelectedDayWithView(DateTime day, String view) {
    state = state.copyWith(
      selectedDay: day,
      displayedMonth: DateTime(day.year, day.month, 1),
      view: view,
    );
    load();
  }

  void goToToday() {
    final now = DateTime.now();
    state = state.copyWith(
      displayedMonth: DateTime(now.year, now.month, 1),
      selectedDay: now,
    );
    load();
  }

  /// 拖动改期到具体时刻（含时分，支持跨天；拖进时间轴即非全天）
  Future<void> moveTaskToDateTime(int taskId, DateTime target) async {
    final t = await _db.getTask(taskId);
    if (t == null) return;
    SoundService.instance.play(SoundKind.drop);
    Haptics.light();
    // P0-3.2：改期前先取消旧任务全部通知
    await _scheduler.cancelTask(taskId);
    final ps = t.planStart;
    final pe = t.planEnd;
    final dur = (pe != null && ps != null)
        ? pe.difference(ps)
        : const Duration(hours: 1);
    // C5-1：落点吸附"时长不跨天"约束——拖到 23:00 且时长跨过午夜时
    // 回退起点（此前 1 小时任务拖到 23:00 变跨天、跳进置顶区且无法拖回）
    var start = target;
    if (start.add(dur).isAfter(
      DateTime(start.year, start.month, start.day, 23, 0),
    )) {
      start = DateTime(
        start.year,
        start.month,
        start.day,
        23,
        0,
      ).subtract(dur);
    }
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
      await _scheduler.scheduleTask(updated, DateTime.now());
    }
    _bump();
    load();
  }

  // ---------- 重复任务：整个系列改期（拖动） ----------

  /// 系列改期撤销快照
  _SeriesReschedule? _seriesUndo;

  /// 重复任务拖动改期：整个系列（含清理旧完成记录，可撤销）
  Future<void> moveTaskToDateTimeSeries(int taskId, DateTime target) async {
    final t = await _db.getTask(taskId);
    if (t == null || t.rrule.isEmpty) return;
    SoundService.instance.play(SoundKind.drop);
    // 批4-3：拖拽改期强度统一为 light（此前单次 light/系列 medium 不一致）
    Haptics.light();
    // P0-3.2：系列改期前先取消旧规则全部通知
    await _scheduler.cancelTask(taskId);
    final oldStart = t.planStart;
    final oldEnd = t.planEnd;
    final dur = (oldEnd != null && oldStart != null)
        ? oldEnd.difference(oldStart)
        : const Duration(hours: 1);
    // C5-1：系列改期同样应用"时长不跨天"约束
    var start = target;
    if (start.add(dur).isAfter(
      DateTime(start.year, start.month, start.day, 23, 0),
    )) {
      start = DateTime(
        start.year,
        start.month,
        start.day,
        23,
        0,
      ).subtract(dur);
    }
    await _db.updateTask(
      taskId,
      TasksCompanion(
        planStart: Value(start),
        planEnd: Value(start.add(dur)),
        isAllDay: const Value(false),
      ),
    );
    // 清理不再匹配新系列的旧完成记录（保存快照供撤销恢复）
    final removed = await _db.pruneCompletionsForTask(taskId, start, t.rrule);
    _seriesUndo = _SeriesReschedule(
      taskId: taskId,
      oldStart: oldStart,
      oldEnd: oldEnd,
      removedCompletions: removed,
    );
    final updated = await _db.getTask(taskId);
    if (updated != null) {
      await _scheduler.scheduleTask(updated, DateTime.now());
    }
    _bump();
    load();
  }

  /// 撤销系列改期（恢复原计划时间 + 被清理的完成记录）
  Future<void> undoMoveTaskSeries() async {
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
    final updated = await _db.getTask(s.taskId);
    if (updated != null) {
      await _scheduler.scheduleTask(updated, DateTime.now());
    }
    _bump();
    load();
  }

  /// 任务完成/恢复（日历直接勾选）
  Future<void> toggleComplete(CalendarItem item) async {
    if (item.completed) {
      if (item.task.rrule.isNotEmpty) {
        await _db.uncompleteInstance(item.task.id, item.instanceDate);
        // 恢复实例后重排：该实例提醒重新排上
        final fresh = await _db.getTask(item.task.id);
        if (fresh != null) {
          await _scheduler.scheduleTask(fresh, DateTime.now());
        }
      } else {
        await _db.reopenTask(item.task.id);
      }
      SoundService.instance.play(SoundKind.reopen);
      Haptics.light();
    } else {
      if (item.task.rrule.isNotEmpty) {
        await _db.completeInstance(item.task.id, item.instanceDate);
        // 完成实例后重排：取消该实例已排提醒，其余未完成实例保留
        final fresh = await _db.getTask(item.task.id);
        if (fresh != null) {
          await _scheduler.scheduleTask(fresh, DateTime.now());
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
    final t = await _db.getTask(taskId);
    if (t == null) return;
    SoundService.instance.play(SoundKind.skip);
    Haptics.light();
    // P0-3.1：跳过日期归一化到当天 00:00
    final day = DateUtilsEx.normalizeInstanceDate(instanceDate);
    final skipped = (jsonDecode(t.skippedDates) as List)
        .map((e) => e as String)
        .toList();
    skipped.add(day.toIso8601String());
    // C1-1：跳过实例时清理当天完成记录（与任务页 skipInstance 一致）
    await _db.uncompleteInstance(taskId, day);
    await _db.updateTask(
      taskId,
      TasksCompanion(skippedDates: Value(jsonEncode(skipped))),
    );
    // 重新取任务：旧快照 skippedDates 不含本次跳过，重排会重新排上该实例
    final fresh = await _db.getTask(taskId);
    if (fresh != null) {
      await _scheduler.scheduleTask(fresh, DateTime.now());
    }
    _bump();
    load();
  }

  /// 撤销跳过实例（从 skippedDates 移除日期）
  Future<void> unskipInstance(int taskId, DateTime instanceDate) async {
    final t = await _db.getTask(taskId);
    if (t == null) return;
    SoundService.instance.play(SoundKind.reopen);
    Haptics.light();
    final day = DateUtilsEx.normalizeInstanceDate(instanceDate);
    final skipped = (jsonDecode(t.skippedDates) as List)
        .map((e) => e as String)
        .toList();
    skipped.remove(day.toIso8601String());
    await _db.updateTask(
      taskId,
      TasksCompanion(skippedDates: Value(jsonEncode(skipped))),
    );
    final fresh = await _db.getTask(taskId);
    if (fresh != null) {
      await _scheduler.scheduleTask(fresh, DateTime.now());
    }
    _bump();
    load();
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

/// 系列改期撤销快照（原计划时间 + 被清理的完成记录）
class _SeriesReschedule {
  final int taskId;
  final DateTime? oldStart;
  final DateTime? oldEnd;
  final List<TaskCompletion> removedCompletions;

  _SeriesReschedule({
    required this.taskId,
    required this.oldStart,
    required this.oldEnd,
    required this.removedCompletions,
  });
}
