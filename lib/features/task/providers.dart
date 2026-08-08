import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

class TasksState {
  final List<TaskList> lists;
  final int? currentListId; // null = 智能清单
  final String smartView; // today / week7 / all / done / list / search
  final List<Task> tasks;
  final String searchQuery;
  final String sortMode; // manual / time / quadrant
  final bool loading;
  /// 重复任务：今天实例是否已完成（今天命中规则时才有意义）
  final Map<int, bool> instanceDone;
  /// 重复任务：下一个未完成实例日期（今天起；系列已结束/全部完成则为 null）
  final Map<int, DateTime?> nextInstance;
  /// 重复任务：今天是否命中规则
  final Map<int, bool> todayHas;

  /// P1-4.4：copyWith 的哨兵——显式清除 currentListId
  /// （参数传 null 表示"不修改"，传本哨兵表示"设置为 null"）
  static const _clearCurrentListId = _ClearListIdSentinel();

  const TasksState({
    this.lists = const [],
    this.currentListId,
    this.smartView = 'all',
    this.tasks = const [],
    this.searchQuery = '',
    this.sortMode = 'manual',
    this.loading = true,
    this.instanceDone = const {},
    this.nextInstance = const {},
    this.todayHas = const {},
  });

  TasksState copyWith({
    List<TaskList>? lists,
    Object? currentListId,
    String? smartView,
    List<Task>? tasks,
    String? searchQuery,
    String? sortMode,
    bool? loading,
    Map<int, bool>? instanceDone,
    Map<int, DateTime?>? nextInstance,
    Map<int, bool>? todayHas,
  }) => TasksState(
    lists: lists ?? this.lists,
    currentListId: identical(currentListId, _clearCurrentListId)
        ? null
        : (currentListId as int?) ?? this.currentListId,
    smartView: smartView ?? this.smartView,
    tasks: tasks ?? this.tasks,
    searchQuery: searchQuery ?? this.searchQuery,
    sortMode: sortMode ?? this.sortMode,
    loading: loading ?? this.loading,
    instanceDone: instanceDone ?? this.instanceDone,
    nextInstance: nextInstance ?? this.nextInstance,
    todayHas: todayHas ?? this.todayHas,
  );
}

/// P1-4.4：currentListId 显式清除哨兵类型
class _ClearListIdSentinel {
  const _ClearListIdSentinel();
}

class TasksController extends StateNotifier<TasksState> {
  TasksController(this._db, this._scheduler, this._ref)
    : super(const TasksState()) {
    // 日历/统计等其他入口写入数据后 bump 数据版本，此处自动刷新
    _ref.listen<int>(dataVersionProvider, (prev, next) {
      if (prev != next) _reloadTasks();
    });
    init();
  }

  final AppDatabase _db;
  final ReminderScheduler _scheduler;
  final Ref _ref;

  /// 数据变更后通知日历等依赖方（I3）。
  /// 注意：本控制器写操作末尾显式调用，勿放入 _reloadTasks（会与上面的监听
  /// 形成自增死循环）。
  void _bump() {
    _ref.read(dataVersionProvider.notifier).state++;
  }

  Future<void> init() async {
    await _db.ensureDefaultList();
    await _reloadLists();
    await _reloadTasks();
  }

  Future<void> _reloadLists() async {
    final lists = await _db.getAllLists();
    state = state.copyWith(lists: lists);
    if (state.currentListId != null) {
      final exists = lists.any((l) => l.id == state.currentListId);
      if (!exists) {
        state = state.copyWith(
          currentListId: TasksState._clearCurrentListId,
          smartView: 'all',
        );
      }
    }
  }

  Future<void> _reloadTasks() async {
    List<Task> tasks;
    final q = state.searchQuery;
    if (q.isNotEmpty) {
      tasks = await _db.searchTasks(q);
      state = state.copyWith(smartView: 'search');
    } else if (state.smartView == 'today') {
      tasks = await _db.getTasksForDate(DateTime.now());
    } else if (state.smartView == 'week7') {
      tasks = await _db.getTasksNext7Days(DateTime.now());
    } else if (state.smartView == 'all') {
      tasks = await _db.getAllUncompleted();
    } else if (state.smartView == 'done') {
      tasks = await _db.getCompletedTasks();
    } else if (state.currentListId != null) {
      tasks = await _db.getTasksByList(state.currentListId!);
      // C8-7：清单视图与"全部"口径一致——过滤已完成（此前已完成任务
      // 在清单里带删除线永久留存，且无清除入口）
      tasks = tasks
          .where((t) => t.parentId == null && t.completedAt == null)
          .toList();
    } else {
      tasks = await _db.getAllUncompleted();
    }
    state = state.copyWith(
      tasks: _sort(tasks),
      loading: false,
      instanceDone: await _loadInstanceDone(tasks),
      nextInstance: await _loadNextInstances(tasks),
      todayHas: await _loadTodayHas(tasks),
    );
  }

  /// 重复任务"今天实例"完成状态
  Future<Map<int, bool>> _loadInstanceDone(List<Task> tasks) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final result = <int, bool>{};
    for (final t in tasks) {
      if (t.rrule.isEmpty) continue;
      result[t.id] = await _db.isInstanceCompleted(t.id, today);
    }
    return result;
  }

  /// 重复任务"今天是否命中规则"
  Future<Map<int, bool>> _loadTodayHas(List<Task> tasks) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final result = <int, bool>{};
    for (final t in tasks) {
      if (t.rrule.isEmpty) continue;
      result[t.id] = (await _db.expandTaskForDate(t, today)).isNotEmpty;
    }
    return result;
  }

  /// 重复任务"下一个未完成实例"（今天起向后找；系列已结束/全部完成 → null）
  Future<Map<int, DateTime?>> _loadNextInstances(List<Task> tasks) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final result = <int, DateTime?>{};
    for (final t in tasks) {
      if (t.rrule.isEmpty) continue;
      result[t.id] = await _nextInstanceDate(t, today);
    }
    return result;
  }

  Future<DateTime?> _nextInstanceDate(Task t, DateTime today) async {
    final base = t.planStart ?? t.createdAt;
    final instances = RruleService.instance.expand(
      base,
      t.rrule,
      from: today,
      to: today.add(const Duration(days: 370)),
      limit: 400,
    );
    for (final inst in instances) {
      if ((await _db.expandTaskForDate(t, inst)).isEmpty) continue;
      if (await _db.isInstanceCompleted(t.id, inst)) continue;
      return inst;
    }
    // P1-4.6：系列已结束或未来实例全部完成 → 无下次实例（不回落今天）
    return null;
  }

  List<Task> _sort(List<Task> tasks) {
    final sorted = List<Task>.from(tasks);
    switch (state.sortMode) {
      case 'time':
        sorted.sort((a, b) {
          final at = _sortTime(a);
          final bt = _sortTime(b);
          return at.compareTo(bt);
        });
        break;
      case 'quadrant':
        sorted.sort((a, b) {
          final qa = a.quadrant;
          final qb = b.quadrant;
          if (qa != qb) return qa.compareTo(qb);
          return _sortTime(a).compareTo(_sortTime(b));
        });
        break;
      default:
        sorted.sort((a, b) {
          final c = a.sortOrder.compareTo(b.sortOrder);
          if (c != 0) return c;
          return a.createdAt.compareTo(b.createdAt);
        });
    }
    return sorted;
  }

  DateTime _sortTime(Task t) {
    final ps = t.planStart;
    if (ps == null) return DateTime(0);
    return DateTime(ps.year, ps.month, ps.day, ps.hour, ps.minute);
  }

  void selectList(int id) {
    // 搜索修复：切换视图必须清空搜索词——否则 _reloadTasks 顶部
    // `if (q.isNotEmpty)` 会强制回到搜索结果，无法离开搜索状态
    state = state.copyWith(
      currentListId: id,
      smartView: 'list',
      searchQuery: '',
    );
    _reloadTasks();
  }

  void selectSmartView(String v) {
    // 搜索修复：切换智能视图同样清空搜索词
    state = state.copyWith(
      smartView: v,
      currentListId: TasksState._clearCurrentListId,
      searchQuery: '',
    );
    _reloadTasks();
  }

  void setSortMode(String mode) {
    state = state.copyWith(sortMode: mode);
    state = state.copyWith(tasks: _sort(state.tasks));
  }

  void search(String q) {
    state = state.copyWith(searchQuery: q);
    _reloadTasks();
  }

  void clearSearch() {
    state = state.copyWith(searchQuery: '');
    state = state.copyWith(
      smartView: 'all',
      currentListId: TasksState._clearCurrentListId,
    );
    _reloadTasks();
  }

  /// 重新加载当前视图（下拉刷新用；不改变当前 smartView/清单/搜索）
  Future<void> reload() => _reloadTasks();

  /// 添加任务，返回新任务 id
  Future<int> addTask({
    required String title,
    String note = '',
    int? listId,
    int quadrant = 4,
    DateTime? planStart,
    DateTime? planEnd,
    DateTime? dueTime,
    bool isAllDay = false,
    String rrule = '',
    String color = '',
    int? parentId,
  }) async {
    SoundService.instance.play(SoundKind.add);
    Haptics.light();
    // A13：重复任务锚点吸附——planStart 不命中规则时吸附到最近命中日
    //（与详情页改规则 / 启动 fixOrphan 同一函数收口；否则如"每2周"等
    // 规则锚点落今天、本周窗口无实例，任务创建后从日历"消失"）
    var ps = planStart;
    var pe = planEnd;
    if (rrule.isNotEmpty && ps != null) {
      final hit = RruleService.instance.nearestHitOnOrNear(ps, rrule);
      if (hit != null &&
          !(hit.year == ps.year && hit.month == ps.month && hit.day == ps.day)) {
        final dur = pe?.difference(ps);
        ps = DateTime(hit.year, hit.month, hit.day, ps.hour, ps.minute);
        pe = dur == null ? ps.add(const Duration(hours: 1)) : ps.add(dur);
      }
    }
    final targetList =
        listId ?? state.currentListId ?? (await _db.getDefaultList()).id;
    final id = await _db.insertTask(
      TasksCompanion.insert(
        listId: targetList,
        title: title,
        note: Value(note),
        quadrant: Value(quadrant),
        planStart: Value(ps),
        planEnd: Value(pe),
        dueTime: Value(dueTime),
        isAllDay: Value(isAllDay),
        color: Value(color),
        rrule: Value(rrule),
        hasNote: Value(note.isNotEmpty),
        parentId: Value(parentId),
        sortOrder: Value(0),
        createdAt: DateTime.now(),
      ),
    );
    // 新任务排顶部：把现有同清单任务 sortOrder +1，新任务保持 0
    // P1-4.5：排除新任务自身（此前把新任务也 +1，导致排序可能不是置顶）
    await _shiftSortOrders(targetList, parentId, excludeId: id);
    await _reloadTasks();
    final t = await _db.getTask(id);
    if (t != null && (t.planStart != null || t.rrule.isNotEmpty)) {
      await _scheduler.scheduleTask(t, DateTime.now());
    }
    _bump();
    return id;
  }

  Future<void> _shiftSortOrders(
    int listId,
    int? parentId, {
    required int excludeId,
  }) async {
    final tasks = parentId == null
        ? await _db.getTasksByList(listId)
        : await _db.getSubTasks(parentId);
    for (final t in tasks) {
      if (t.id == excludeId) continue;
      await _db.updateTask(
        t.id,
        TasksCompanion(sortOrder: Value(t.sortOrder + 1)),
      );
    }
  }

  Future<int?> addTaskFromParsed(
    String title,
    ParseResult parsed, {
    int? listId,
  }) async {
    final now = DateTime.now();
    DateTime? ps;
    DateTime? pe;
    var isAllDay = false;
    if (parsed.time != null) {
      isAllDay = false;
      final date = parsed.date ?? now;
      ps = DateTime(
        date.year,
        date.month,
        date.day,
        parsed.time!.hour,
        parsed.time!.minute,
      );
      if (parsed.endTime != null) {
        var eh = parsed.endTime!.hour;
        final em = parsed.endTime!.minute;
        if (eh < parsed.time!.hour) {
          pe = DateTime(date.year, date.month, date.day + 1, eh, em);
        } else {
          pe = DateTime(date.year, date.month, date.day, eh, em);
        }
      } else {
        pe = ps.add(const Duration(hours: 1));
      }
    } else if (parsed.date != null && parsed.rrule.isEmpty) {
      isAllDay = true;
      final d = parsed.date!;
      ps = DateTime(d.year, d.month, d.day);
      pe = DateTime(d.year, d.month, d.day + 1);
    }
    if (ps == null && parsed.rrule.isNotEmpty) {
      // P1-4.7：重复任务起始日期用解析出的日期（此前"明天每天阅读"
      // 会忽略日期直接落到今天）；无明确时间 → 全天任务
      isAllDay = true;
      final d = parsed.date ?? now;
      ps = DateTime(d.year, d.month, d.day);
      pe = DateTime(d.year, d.month, d.day + 1);
    }
    return addTask(
      title: title,
      listId: listId,
      planStart: ps,
      planEnd: pe,
      isAllDay: isAllDay,
      rrule: parsed.rrule,
    );
  }

  /// 更新任务字段。返回提醒是否全部成功排期（P1-4.9，供 UI 提示权限问题）。
  Future<bool> updateTaskFields(int id, TasksCompanion changes) async {
    // P0-3.2：先基于旧任务快照取消全部旧通知，再写入新任务，
    // 最后按新任务重排（避免改期/改规则后旧日期的提醒残留）
    await _scheduler.cancelTask(id);
    await _db.updateTask(id, changes);
    await _reloadTasks();
    final t = await _db.getTask(id);
    var ok = true;
    if (t != null) {
      ok = await _scheduler.scheduleTask(t, DateTime.now());
    }
    _bump();
    return ok;
  }

  /// 完成/撤销当前实例（重复任务为切换：已完成则撤销，未完成则完成）
  /// [silent]：批量操作时静默（避免逐条播声音/震动，由批量方法统一播放一次）
  /// 返回写入/撤销的实例日期（重复任务；非重复为 null）——
  /// C1-2：UI 据此提示实际操作的实例日（未来系列"点了没反应"问题）
  Future<DateTime?> completeTask(int id, {bool silent = false}) async {
    final t = await _db.getTask(id);
    if (t == null) return null;
    if (!silent) {
      SoundService.instance.play(SoundKind.complete);
      Haptics.medium();
    }
    if (t.rrule.isNotEmpty) {
      final inst = _currentInstanceDate(t);
      final done = await _db.isInstanceCompleted(id, inst);
      if (done) {
        await _db.uncompleteInstance(id, inst);
      } else {
        await _db.completeInstance(id, inst);
      }
      // 完成/撤销实例后重排：取消该实例已排提醒，其余未完成实例保留
      final fresh = await _db.getTask(id);
      if (fresh != null) {
        await _scheduler.scheduleTask(fresh, DateTime.now());
      }
      await _reloadTasks();
      // C2：子任务全完成时自动完成父任务（含重复子任务的今日实例对齐）
      final parentId = t.parentId;
      if (parentId != null) {
        await _db.maybeAutoCompleteParent(parentId);
        // 父任务被联动完成/恢复时同步重排其提醒
        final parent = await _db.getTask(parentId);
        if (parent != null && parent.rrule.isNotEmpty) {
          await _scheduler.scheduleTask(parent, DateTime.now());
        }
        await _reloadTasks();
      }
      _bump();
      return inst;
    }
    await _db.completeTask(id);
    await _scheduler.cancelTask(id);
    await _reloadTasks();
    _bump();
    return null;
  }

  /// 重复任务实例完成
  Future<void> completeInstance(int id, DateTime instanceDate) async {
    final t = await _db.getTask(id);
    if (t == null) return;
    SoundService.instance.play(SoundKind.complete);
    Haptics.medium();
    if (t.rrule.isNotEmpty) {
      await _db.completeInstance(id, instanceDate);
      // 完成实例后重排：取消该实例已排提醒，其余未完成实例保留
      final fresh = await _db.getTask(id);
      if (fresh != null) {
        await _scheduler.scheduleTask(fresh, DateTime.now());
      }
    } else {
      await _db.completeTask(id);
      await _scheduler.cancelTask(id);
    }
    await _reloadTasks();
    _bump();
  }

  DateTime _currentInstanceDate(Task t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final ps = t.planStart;
    if (ps == null) return today;
    final psDay = DateTime(ps.year, ps.month, ps.day);
    // 未来实例提前完成 → 记录到计划日（日历上该实例显示已完成）；
    // 已开始/过去的系列 → 默认完成今天的实例
    return psDay.isAfter(today) ? psDay : today;
  }

  Future<void> reopenTask(int id, {bool silent = false}) async {
    final t = await _db.getTask(id);
    if (t == null) return;
    if (!silent) {
      SoundService.instance.play(SoundKind.reopen);
      Haptics.light();
    }
    if (t.rrule.isEmpty) {
      await _db.reopenTask(id);
    } else {
      final inst = _currentInstanceDate(t);
      await _db.uncompleteInstance(id, inst);
    }
    await _reloadTasks();
    // 反向联动：子任务恢复未完成时，父任务同步恢复未完成（含重复子任务）
    final parentId = t.parentId;
    if (parentId != null) {
      await _db.maybeReopenParent(parentId);
      // P0-4：父任务被联动恢复时同步重排其提醒（此前仅 completeTask 侧
      // 有联动重排，reopen 侧漏掉——父任务恢复后提醒静默丢失）
      final parent = await _db.getTask(parentId);
      if (parent != null) {
        // 父任务仍完成（其他子任务未完成）时 scheduleTask 内部会取消提醒
        await _scheduler.scheduleTask(parent, DateTime.now());
      }
      await _reloadTasks();
    }
    // 重新取任务：旧快照 completedAt 非空会让重排直接跳过
    final fresh = await _db.getTask(id);
    if (fresh != null) {
      await _scheduler.scheduleTask(fresh, DateTime.now());
    }
    _bump();
  }

  Future<void> deleteTask(int id) async {
    SoundService.instance.play(SoundKind.delete);
    // 批4-1：删除震动 heavy→medium（heavy 过强）
    Haptics.medium();
    // P0-3.4：整棵子树的通知全部取消（子任务的提醒不再残留）
    final subs = await _collectSubtree(id);
    for (final tid in [id, ...subs.map((s) => s.id)]) {
      await _scheduler.cancelTask(tid);
    }
    await _db.deleteTask(id);
    await _reloadTasks();
    _bump();
  }

  // D1：删除撤销缓存（P2：限容——超出上限丢弃最旧快照，防止长期不撤销时内存增长）
  final Map<int, _DeletedSnapshot> _deletedCache = {};
  static const int _deletedCacheLimit = 50;

  // P0-2：跳过实例时被删除的完成记录暂存（撤销跳过时恢复原完成时间）。
  // 撤销条 3 秒内有效，同限容策略防止内存增长。
  final Map<String, DateTime> _skippedCompletionCache = {};
  static const int _skippedCompletionCacheLimit = 50;

  /// 递归收集任务子树（含自身后代，不含根）
  Future<List<Task>> _collectSubtree(int id) async {
    final result = <Task>[];
    final queue = <int>[id];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      final children = await _db.getSubTasks(cur);
      result.addAll(children);
      queue.addAll(children.map((c) => c.id));
    }
    return result;
  }

  /// 删除任务并支持撤销（缓存快照：任务 + 子树 + 提醒 + 完成记录 + 例外 + 番茄记录）
  Future<void> deleteTaskWithUndo(int id) async {
    final t = await _db.getTask(id);
    if (t == null) return;
    final subs = await _collectSubtree(id);
    final allIds = [id, ...subs.map((s) => s.id)];
    // P0-3.4：整棵树的提醒全部取消（子任务通知不再残留）
    for (final tid in allIds) {
      await _scheduler.cancelTask(tid);
    }
    // P0-3.4：快照保存整棵树所有关联数据（此前漏了子任务提醒与番茄记录）
    final reminders = <Reminder>[];
    for (final tid in allIds) {
      reminders.addAll(await _db.getReminders(tid));
    }
    final completions = await (_db.select(
      _db.taskCompletions,
    )..where((c) => c.taskId.isIn(allIds))).get();
    final exceptions = await (_db.select(
      _db.taskExceptions,
    )..where((e) => e.taskId.isIn(allIds))).get();
    final pomodoros = await (_db.select(
      _db.pomodoroRecords,
    )..where((p) => p.taskId.isIn(allIds))).get();
    _deletedCache[id] = _DeletedSnapshot(
      t,
      subs,
      reminders,
      completions,
      exceptions,
      pomodoros,
    );
    // P2：限容——超出上限丢弃最旧快照（Map 保持插入序，keys.first 最旧）
    while (_deletedCache.length > _deletedCacheLimit) {
      _deletedCache.remove(_deletedCache.keys.first);
    }
    await _db.deleteTask(id);
    // P1-A：删除主路径必须 bump，否则日历/四象限/统计常驻页不刷新
    _bump();
  }

  /// 撤销删除（P0-3.4/3.5：恢复任务 + 子树 + 完整提醒 + 完成记录 + 例外 + 番茄记录，
  /// 全部在同一事务内执行）
  /// [silent]：批量撤销时静默（批4-2：此前批量撤销逐条播音效+震动）
  Future<void> undoDelete(int id, {bool silent = false}) async {
    final snap = _deletedCache.remove(id);
    if (snap == null) return;
    if (!silent) {
      SoundService.instance.play(SoundKind.reopen);
      Haptics.light();
    }
    await _db.transaction(() async {
      await _db.restoreTask(snap.task);
      for (final s in snap.subTasks) {
        await _db.restoreTask(s);
      }
      for (final r in snap.reminders) {
        await _db.insertReminderRaw(
          RemindersCompanion(
            id: Value(r.id),
            taskId: Value(r.taskId),
            remindMinutesBefore: Value(r.remindMinutesBefore),
            isPersistent: Value(r.isPersistent),
            // P0-3.5：恢复全天任务提醒时刻（旧快照缺该字段时保持 null = 默认 09:00）
            remindAtMinutes: r.remindAtMinutes == null
                ? const Value(null)
                : Value(r.remindAtMinutes),
          ),
        );
      }
      for (final c in snap.completions) {
        await _db.insertCompletionRaw(
          TaskCompletionsCompanion(
            id: Value(c.id),
            taskId: Value(c.taskId),
            instanceDate: Value(c.instanceDate),
            completedAt: Value(c.completedAt),
          ),
        );
      }
      for (final e in snap.exceptions) {
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
      for (final p in snap.pomodoros) {
        await _db.insertPomodoroRaw(
          PomodoroRecordsCompanion(
            id: Value(p.id),
            taskId: p.taskId == null ? const Value(null) : Value(p.taskId),
            durationMinutes: Value(p.durationMinutes),
            startedAt: Value(p.startedAt),
            completedAt: Value(p.completedAt),
          ),
        );
      }
    });
    await _reloadTasks();
    // 整棵树恢复后重排全部提醒（含子任务）
    for (final tid in [snap.task.id, ...snap.subTasks.map((s) => s.id)]) {
      final restored = await _db.getTask(tid);
      if (restored != null) {
        await _scheduler.scheduleTask(restored, DateTime.now());
      }
    }
    _bump();
  }

  Future<void> reorder(List<int> orderedIds) async {
    // 拖拽排序会修改 sortOrder：若非手动排序模式，自动切回手动（否则刷新被排回去）
    if (state.sortMode != 'manual') {
      state = state.copyWith(sortMode: 'manual');
    }
    await _db.reorderTasks(orderedIds);
    // 本地重排，避免全量 reload 导致列表重建闪烁
    final current = List<Task>.from(state.tasks);
    final byId = {for (final t in current) t.id: t};
    final reordered = orderedIds
        .map((id) => byId[id])
        .whereType<Task>()
        .toList();
    state = state.copyWith(tasks: reordered);
    _bump();
  }

  /// 批量完成，返回**实际完成的任务 id 集合**（P0-1：撤销条必须按此集合
  /// 回滚，否则被跳过项会被误撤销——此前跳过的"今日已完成的重复任务"
  /// 会被 batchReopen 反转完成状态）
  Future<List<int>> batchComplete(List<int> ids) async {
    // P2：逐条静默执行，完成后统一播放一次反馈（此前 20 条响 20 次）
    // C8-2：跳过"今天已完成"的重复任务——completeTask 是切换语义，
    // 批量完成会把它们反过来"撤销完成"（与用户意图相反）
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final acted = <int>[];
    for (final id in ids) {
      final t = await _db.getTask(id);
      if (t == null) continue;
      if (t.rrule.isNotEmpty &&
          await _db.isInstanceCompleted(id, today)) {
        continue;
      }
      // P0-1：非重复任务已完成时同样跳过（completeTask 切换语义会误撤销）
      if (t.completedAt != null) continue;
      await completeTask(id, silent: true);
      acted.add(id);
    }
    if (acted.isEmpty) return acted;
    SoundService.instance.play(SoundKind.complete);
    Haptics.medium();
    await _reloadTasks();
    return acted;
  }

  /// 批量恢复未完成（已完成视图多选用）
  Future<void> batchReopen(List<int> ids) async {
    // P2：逐条静默执行，完成后统一播放一次反馈
    for (final id in ids) {
      await reopenTask(id, silent: true);
    }
    SoundService.instance.play(SoundKind.reopen);
    Haptics.light();
    await _reloadTasks();
  }

  /// 批量删除（逐条存撤销快照，支持批量撤销）
  Future<void> batchDelete(List<int> ids) async {
    for (final id in ids) {
      await deleteTaskWithUndo(id);
    }
    await _reloadTasks();
  }

  /// 批量撤销删除（恢复快照中的任务/子任务/提醒/完成记录）
  /// 批4-2：逐条静默，完成后统一播放一次反馈
  Future<void> batchUndoDelete(List<int> ids) async {
    for (final id in ids) {
      await undoDelete(id, silent: true);
    }
    SoundService.instance.play(SoundKind.reopen);
    Haptics.light();
    await _reloadTasks();
  }

  Future<void> batchMove(List<int> ids, int targetListId) async {
    await _db.batchMove(ids, targetListId);
    await _reloadTasks();
    _bump();
  }

  Future<void> skipInstance(int id, DateTime instanceDate) async {
    final t = await _db.getTask(id);
    if (t == null) return;
    SoundService.instance.play(SoundKind.skip);
    Haptics.light();
    // P0-3.1：跳过日期归一化到当天 00:00（与规则展开/例外基准一致）
    final day = DateUtilsEx.normalizeInstanceDate(instanceDate);
    final skipped = _parseSkippedDates(t.skippedDates);
    if (!skipped.contains(day.toIso8601String())) {
      skipped.add(day.toIso8601String());
    }
    // C1-1：跳过实例时清理当天完成记录——否则"删除本次"后
    // 列表/已完成视图/统计仍认为今天已完成（且该天完成数可大于计划数）
    // P0-2：删除前暂存完成时间，撤销跳过（unskipInstance）时恢复原记录
    if (await _db.isInstanceCompleted(id, day)) {
      final comp = await _db.getInstanceCompletion(id, day);
      if (comp != null) {
        _skippedCompletionCache[_skipCompletionKey(id, day)] = comp.completedAt;
        while (_skippedCompletionCache.length > _skippedCompletionCacheLimit) {
          _skippedCompletionCache.remove(_skippedCompletionCache.keys.first);
        }
      }
    }
    await _db.uncompleteInstance(id, day);
    await _db.updateTask(
      id,
      TasksCompanion(skippedDates: Value(jsonEncode(skipped))),
    );
    await _reloadTasks();
    // 重新取任务：旧快照的 skippedDates 不含本次跳过，会让重排重新排上该实例
    final fresh = await _db.getTask(id);
    if (fresh != null) {
      await _scheduler.scheduleTask(fresh, DateTime.now());
    }
    _bump();
  }

  /// 撤销跳过：从 skippedDates 移除指定日期（删除本次/跳过的撤销）
  Future<void> unskipInstance(int id, DateTime instanceDate) async {
    final t = await _db.getTask(id);
    if (t == null) return;
    final day = DateUtilsEx.normalizeInstanceDate(instanceDate);
    final skipped = _parseSkippedDates(t.skippedDates);
    skipped.remove(day.toIso8601String());
    // P0-2：撤销跳过恢复被删除的完成记录（保留原完成时间，统计不漂移）
    final cachedAt = _skippedCompletionCache.remove(_skipCompletionKey(id, day));
    if (cachedAt != null) {
      await _db.restoreInstanceCompletion(id, day, cachedAt);
    }
    await _db.updateTask(
      id,
      TasksCompanion(skippedDates: Value(jsonEncode(skipped))),
    );
    await _reloadTasks();
    // 重新取任务：旧快照仍含被移除的跳过日期，会让重排漏排该实例
    final fresh = await _db.getTask(id);
    if (fresh != null) {
      await _scheduler.scheduleTask(fresh, DateTime.now());
    }
    _bump();
  }

  /// P1-12：skippedDates 非法 JSON（损坏备份导入等）静默视为无跳过，
  /// 避免跳过/撤销操作直接抛 FormatException
  static List<String> _parseSkippedDates(String raw) {
    if (raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => e as String).toList();
    } catch (_) {
      return [];
    }
  }

  static String _skipCompletionKey(int taskId, DateTime day) =>
      '$taskId:${day.toIso8601String()}';

  /// 列表页操作用的"当前实例日期"（供 UI 显示/删除选择框）
  static DateTime currentInstanceDate(Task t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final ps = t.planStart;
    if (ps == null) return today;
    final psDay = DateTime(ps.year, ps.month, ps.day);
    return psDay.isAfter(today) ? psDay : today;
  }

  /// 改期本次实例（写例外）。返回例外记录 ID：
  /// 撤销时用 [undoEditException] 删除该记录恢复原状，而不是新增反向例外（P0-3.3）。
  Future<int> editException(int id, DateTime fromDate, DateTime toDate) async {
    final t = await _db.getTask(id);
    if (t == null) return -1;
    final existing = await _db.getExceptions(id);
    for (final ex in existing) {
      if (DateUtilsEx.sameDay(ex.instanceDate, fromDate)) {
        await _db.updateException(ex.id, toDate);
        await _reloadTasks();
        // 更新既有例外同样需重排：新日期（及原日期取消）的提醒
        final fresh = await _db.getTask(id);
        if (fresh != null) {
          await _scheduler.scheduleTask(fresh, DateTime.now());
        }
        _bump();
        return ex.id;
      }
    }
    final exId = await _db.insertException(
      TaskExceptionsCompanion.insert(
        taskId: id,
        instanceDate: fromDate,
        action: const Value('edit'),
        overrideScheduledDate: Value(toDate),
      ),
    );
    await _reloadTasks();
    await _scheduler.scheduleTask(t, DateTime.now());
    _bump();
    return exId;
  }

  /// 撤销单次改期：删除该例外记录（原实例恢复到原日期，不新增反向例外）
  Future<void> undoEditException(int id, int exceptionId) async {
    await _db.deleteException(exceptionId);
    await _reloadTasks();
    final t = await _db.getTask(id);
    if (t != null) {
      await _scheduler.scheduleTask(t, DateTime.now());
    }
    _bump();
  }

  // 清单操作
  Future<int> createList(String name, String color) async {
    final lists = await _db.getAllLists();
    final id = await _db.insertList(name, color, lists.length);
    await _reloadLists();
    _bump();
    return id;
  }

  Future<void> renameList(int id, String name) async {
    await _db.updateList(id, name: name);
    await _reloadLists();
    _bump();
  }

  Future<void> changeListColor(int id, String color) async {
    await _db.updateList(id, color: color);
    await _reloadLists();
    _bump();
  }

  Future<void> toggleListCalendar(int id, bool show) async {
    await _db.updateList(id, showInCalendar: show);
    await _reloadLists();
    _bump();
  }

  Future<void> reorderLists(List<int> orderedIds) async {
    await _db.reorderLists(orderedIds);
    await _reloadLists();
    _bump();
  }

  Future<void> deleteList(int id, {bool deleteTasks = false}) async {
    // 默认清单（收件箱）不可删除：删除后无默认清单会导致后续操作异常
    final list = state.lists.where((l) => l.id == id).firstOrNull;
    if (list?.isDefault ?? false) return;
    await _db.deleteList(id, deleteTasks: deleteTasks);
    if (state.currentListId == id) {
      state = state.copyWith(
        currentListId: TasksState._clearCurrentListId,
        smartView: 'all',
      );
    }
    await _reloadLists();
    await _reloadTasks();
    _bump();
  }

  /// C8-7：清空全部已完成任务（含重复任务实例完成记录），确认后调用
  Future<void> clearCompleted() async {
    await _db.clearCompletedTasks();
    await _reloadTasks();
    _bump();
  }
}

/// D1：删除撤销快照
class _DeletedSnapshot {
  final Task task;
  final List<Task> subTasks;
  final List<Reminder> reminders;
  final List<TaskCompletion> completions;
  final List<TaskException> exceptions;
  final List<PomodoroRecord> pomodoros;

  _DeletedSnapshot(
    this.task,
    this.subTasks,
    this.reminders,
    this.completions,
    this.exceptions,
    this.pomodoros,
  );
}

final tasksControllerProvider =
    StateNotifierProvider<TasksController, TasksState>((ref) {
      return TasksController(
        ref.read(dbProvider),
        ref.read(reminderSchedulerProvider),
        ref,
      );
    });
