import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

import '../../core/utils/date_utils.dart' as du;
import '../services/rrule_expander.dart';
import '../../core/utils/app_clock.dart';

part 'database.g.dart';

/// 清单
@DataClassName('TaskList')
class Lists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get color => text().withDefault(const Constant('#4F8EF7'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get showInCalendar =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
}

/// 任务
class Tasks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get listId => integer().references(Lists, #id)();
  IntColumn get parentId => integer().nullable().references(Tasks, #id)();
  TextColumn get title => text()();
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get quadrant => integer().withDefault(const Constant(4))();
  DateTimeColumn get planStart => dateTime().nullable()();
  DateTimeColumn get planEnd => dateTime().nullable()();
  DateTimeColumn get dueTime => dateTime().nullable()();
  BoolColumn get isAllDay => boolean().withDefault(const Constant(false))();
  TextColumn get rrule => text().withDefault(const Constant(''))();
  TextColumn get color => text().withDefault(const Constant(''))();
  BoolColumn get hasReminder => boolean().withDefault(const Constant(false))();
  BoolColumn get hasNote => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get skippedDates => text().withDefault(const Constant('[]'))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}

/// 提醒（多提醒）
class Reminders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().references(Tasks, #id)();
  IntColumn get remindMinutesBefore =>
      integer().withDefault(const Constant(0))();
  BoolColumn get isPersistent => boolean().withDefault(const Constant(false))();

  /// 全天任务提醒时刻（当天 0 点起的分钟数，0-1439；null = 默认 09:00）。
  /// 定时任务忽略此字段，始终按 planStart 提前。
  IntColumn get remindAtMinutes => integer().nullable()();
}

/// 完成记录（重复任务实例独立完成）
/// (task_id, instance_date) 唯一：防止重复插入导致 isInstanceCompleted 崩溃
class TaskCompletions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().references(Tasks, #id)();
  DateTimeColumn get instanceDate => dateTime()();
  DateTimeColumn get completedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {taskId, instanceDate},
  ];
}

/// RRULE 例外
class TaskExceptions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().references(Tasks, #id)();
  DateTimeColumn get instanceDate => dateTime()();
  TextColumn get action => text().withDefault(const Constant('edit'))();
  DateTimeColumn get overrideScheduledDate => dateTime().nullable()();
}

/// 习惯（独立实体）
class Habits extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get icon => text().withDefault(const Constant('⭐'))();
  TextColumn get frequency => text().withDefault(const Constant('daily'))();
  DateTimeColumn get reminderTime => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}

/// 习惯打卡记录
class HabitRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get habitId => integer().references(Habits, #id)();
  DateTimeColumn get date => dateTime()();
  DateTimeColumn get completedAt => dateTime()();

  // 同一习惯同一天只能有一条记录——双击打卡竞态并发插入
  // 多条会导致 isHabitDone 的 getSingleOrNull 抛 "Too many elements"
  // 习惯列表加载崩溃（旧库由 v5 迁移去重并建索引）
  @override
  List<Set<Column>> get uniqueKeys => [
    {habitId, date},
  ];
}

/// 番茄专注记录
class PomodoroRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().nullable().references(Tasks, #id)();
  IntColumn get durationMinutes => integer()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime()();
}

/// 设置 KV
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

/// 回收站：已删除任务整棵树快照。
/// 任务删除时仍物理删除，整棵树序列化 JSON 存入 [data]（任务+子树+提醒+
/// 完成记录+例外+番茄），恢复时按原 ID 重建；彻底删除只删本条快照。
/// 备份导出不含回收站；备份恢复（replaceAll）时清空本表，避免旧快照复活。
class TrashItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// 被删任务根 id（撤销恢复后按此删除对应回收站行）
  IntColumn get originalTaskId => integer()();
  TextColumn get title => text()();
  /// 删除时所属清单名快照（清单可能随后被删/改名）
  TextColumn get listName => text()();
  DateTimeColumn get deletedAt => dateTime()();
  /// 整棵树 JSON 快照（encode/decode 见 trash_service.dart）
  TextColumn get data => text()();
}

@DriftDatabase(
  tables: [
    Lists,
    Tasks,
    Reminders,
    TaskCompletions,
    TaskExceptions,
    Habits,
    HabitRecords,
    PomodoroRecords,
    Settings,
    TrashItems,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'zhuoluo'));

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // v3：旧库补唯一索引（新库由表定义 uniqueKeys 自动生成）；
      // 容错：不完整旧库可能无该表（与 v5 同款容错）
      if (details.versionBefore != null && details.versionBefore! < 3) {
        try {
          await _dedupeCompletionsAndIndex();
        } catch (e) {
          debugPrint('v3 启动补索引跳过（task_completions 表缺失）: $e');
        }
      }
      // v5：旧库补习惯打卡唯一索引（新库由表定义 uniqueKeys 自动生成）；
      // 容错：不完整旧库可能无该表
      if (details.versionBefore != null && details.versionBefore! < 5) {
        try {
          await _dedupeHabitRecordsAndIndex();
        } catch (e) {
          debugPrint('v5 启动补索引跳过（habit_records 表缺失）: $e');
        }
      }
    },
    onUpgrade: (m, from, to) async {
      if (from < 6) {
        // v6：回收站表（已删除任务整棵树快照）
        await m.createTable(trashItems);
      }
      if (from < 5) {
        // v5：habit_records 加唯一约束，先清理重复行（双击竞态崩溃修复）。
        // 容错：极旧/不完整库可能无该表（迁移测试手工构造的部分表库），跳过
        try {
          await _dedupeHabitRecordsAndIndex();
        } catch (e) {
          debugPrint('v5 迁移跳过（habit_records 表缺失）: $e');
        }
      }
      if (from < 4) {
        // v4：reminders 增加全天任务提醒时刻字段
        await m.addColumn(reminders, reminders.remindAtMinutes);
      }
      if (from < 3) {
        // v3：task_completions 加唯一约束，先清理重复行（崩溃修复）；
        // 容错：不完整旧库可能无该表（与 v5 同款容错）
        try {
          await _dedupeCompletionsAndIndex();
        } catch (e) {
          debugPrint('v3 迁移跳过（task_completions 表缺失）: $e');
        }
      }
      if (from < 2) {
        // v0.2：scheduled_date+start_time+duration_minutes → plan_start+plan_end；due_date → due_time；新增 color
        await m.addColumn(tasks, tasks.planStart);
        await m.addColumn(tasks, tasks.planEnd);
        await m.addColumn(tasks, tasks.dueTime);
        await m.addColumn(tasks, tasks.color);
        final rows = await customSelect(
          'SELECT id, scheduled_date, start_time, duration_minutes, due_date FROM tasks',
        ).get();
        for (final row in rows) {
          final id = row.read<int>('id');
          final sd = row.read<int?>('scheduled_date');
          final st = row.read<int?>('start_time');
          final dur = row.read<int?>('duration_minutes') ?? 60;
          final dd = row.read<int?>('due_date');
          DateTime? planStart;
          final sdDate = _migrateDateTime(sd);
          if (sdDate != null) {
            var hour = 0;
            var minute = 0;
            final stTime = _migrateDateTime(st);
            if (stTime != null) {
              hour = stTime.hour;
              minute = stTime.minute;
            }
            planStart = DateTime(
              sdDate.year,
              sdDate.month,
              sdDate.day,
              hour,
              minute,
            );
          }
          final planEnd = planStart?.add(Duration(minutes: dur));
          final dueTime = _migrateDateTime(dd);
          await customUpdate(
            'UPDATE tasks SET plan_start = ?1, plan_end = ?2, due_time = ?3 WHERE id = ?4',
            variables: [
              // drift dateTime 列存储 unix 秒，此处保持一致
              Variable(
                planStart == null
                    ? null
                    : planStart.millisecondsSinceEpoch ~/ 1000,
              ),
              Variable(
                planEnd == null ? null : planEnd.millisecondsSinceEpoch ~/ 1000,
              ),
              Variable(
                dueTime == null ? null : dueTime.millisecondsSinceEpoch ~/ 1000,
              ),
              Variable(id),
            ],
          );
        }
      }
    },
  );

  /// v3 迁移：删除 task_completions 中同一 (task_id, instance_date) 的重复行，
  /// 再建唯一索引（已存在则跳过）
  Future<void> _dedupeCompletionsAndIndex() async {
    await customStatement(
      'DELETE FROM task_completions WHERE id NOT IN '
      '(SELECT MIN(id) FROM task_completions GROUP BY task_id, instance_date)',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_task_completions_unique '
      'ON task_completions(task_id, instance_date)',
    );
  }

  /// v5 迁移：删除 habit_records 中同一 (habit_id, date) 的
  /// 重复行（双击打卡竞态历史残留），再建唯一索引
  Future<void> _dedupeHabitRecordsAndIndex() async {
    await customStatement(
      'DELETE FROM habit_records WHERE id NOT IN '
      '(SELECT MIN(id) FROM habit_records GROUP BY habit_id, date)',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_habit_records_unique '
      'ON habit_records(habit_id, date)',
    );
  }

  // ---------- 初始化：预置默认清单 ----------
  Future<void> ensureDefaultList() async {
    final existing = await (select(
      lists,
    )..where((l) => l.isDefault.equals(true))).getSingleOrNull();
    if (existing == null) {
      await into(lists).insert(
        ListsCompanion.insert(
          name: '收件箱',
          isDefault: const Value(true),
          createdAt: AppClock.now(),
        ),
      );
    }
  }

  // ---------- 清单 ----------
  Future<List<TaskList>> getAllLists() async {
    final q = select(lists)..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]);
    return q.get();
  }

  Future<TaskList> getDefaultList() =>
      (select(lists)..where((l) => l.isDefault.equals(true))).getSingle();

  /// 是否存在默认清单（合并导入判断是否可继承备份的默认标记）
  Future<bool> hasDefaultList() async {
    final rows =
        await (select(lists)
              ..where((l) => l.isDefault.equals(true))
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }

  /// 按 id 查清单（不存在返回 null）。默认清单设置读取时校验用。
  Future<TaskList?> getListById(int id) =>
      (select(lists)..where((l) => l.id.equals(id))).getSingleOrNull();

  Future<int> insertList(String name, String color, int sortOrder) =>
      into(lists).insert(
        ListsCompanion.insert(
          name: name,
          color: Value(color),
          sortOrder: Value(sortOrder),
          createdAt: AppClock.now(),
        ),
      );

  Future<void> updateList(
    int id, {
    String? name,
    String? color,
    int? sortOrder,
    bool? showInCalendar,
  }) async {
    await (update(lists)..where((l) => l.id.equals(id))).write(
      ListsCompanion(
        name: name == null ? const Value.absent() : Value(name),
        color: color == null ? const Value.absent() : Value(color),
        sortOrder: sortOrder == null ? const Value.absent() : Value(sortOrder),
        showInCalendar: showInCalendar == null
            ? const Value.absent()
            : Value(showInCalendar),
      ),
    );
  }

  /// 删除清单：转移或连带删除
  Future<void> deleteList(int listId, {bool deleteTasks = false}) async {
    final q = select(tasks)..where((t) => t.listId.equals(listId));
    final rows = await q.get();
    final ids = rows.map((r) => r.id).toList();
    if (ids.isNotEmpty) {
      if (deleteTasks) {
        for (final id in ids) {
          await _deleteTaskRecursive(id);
        }
      } else {
        final def = await getDefaultList();
        await (update(tasks)..where((t) => t.listId.equals(listId))).write(
          TasksCompanion(listId: Value(def.id)),
        );
      }
    }
    await (delete(lists)..where((l) => l.id.equals(listId))).go();
  }

  /// 撤销删除清单：按原 ID 恢复清单行（连带删除撤销用）
  Future<void> restoreList(TaskList l) => into(lists).insertOnConflictUpdate(
    ListsCompanion(
      id: Value(l.id),
      name: Value(l.name),
      color: Value(l.color),
      sortOrder: Value(l.sortOrder),
      showInCalendar: Value(l.showInCalendar),
      isDefault: Value(l.isDefault),
      createdAt: Value(l.createdAt),
    ),
  );

  Future<void> _deleteTaskRecursive(int taskId) async {
    // 整棵子树在同一事务内删除，中途失败自动回滚（避免部分删除）
    await transaction(() async {
      await _deleteSubtree(taskId);
    });
  }

  Future<void> _deleteSubtree(int taskId) async {
    final children = await (select(
      tasks,
    )..where((t) => t.parentId.equals(taskId))).get();
    for (final c in children) {
      await _deleteSubtree(c.id);
    }
    await (delete(reminders)..where((r) => r.taskId.equals(taskId))).go();
    await (delete(taskCompletions)..where((t) => t.taskId.equals(taskId))).go();
    await (delete(taskExceptions)..where((t) => t.taskId.equals(taskId))).go();
    // 删除关联番茄记录（外键引用 Tasks，不删会触发外键错误）
    await (delete(pomodoroRecords)..where((p) => p.taskId.equals(taskId))).go();
    await (delete(tasks)..where((t) => t.id.equals(taskId))).go();
  }

  // ---------- 任务 ----------
  Future<List<Task>> getTasksByList(int listId) =>
      (select(tasks)
            ..where((t) => t.listId.equals(listId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.createdAt),
            ]))
          .get();

  Future<List<Task>> getSubTasks(int parentId) =>
      (select(tasks)
            ..where((t) => t.parentId.equals(parentId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  /// 智能清单：今天（计划开始时间在今天范围内的任务，含跨天任务；重复任务按实例展开）
  Future<List<Task>> getTasksForDate(DateTime day) => _tasksForRange(day, day);

  /// 智能清单：未来 7 天（今天起 7 天，含重复任务实例展开）
  Future<List<Task>> getTasksNext7Days(DateTime today) => _tasksForRange(
    today,
    AppClock.addCalendarDays(today, 6),
  );

  /// 时间范围智能清单（含重复任务实例展开）
  Future<List<Task>> _tasksForRange(DateTime from, DateTime to) async {
    final start = AppClock.at(from.year, from.month, from.day);
    final end = AppClock.nextDay(to);
    final rows =
        await (select(tasks)..where(
              (t) =>
                  // 非重复任务：按计划区间/截止时间判断
                  (t.rrule.equals('') &
                      (t.planStart.isSmallerThanValue(end) &
                          t.planEnd.isBiggerOrEqualValue(start))) |
                  (t.rrule.equals('') &
                      t.planStart.isNull() &
                      t.dueTime.isBiggerOrEqualValue(start) &
                      t.dueTime.isSmallerThanValue(end)) |
                  // 重复任务：planStart 早于窗口结束（或未设计划时间）即可能命中窗口内某天
                  (t.rrule.isNotValue('') &
                      (t.planStart.isNull() |
                          t.planStart.isSmallerThanValue(end))),
            ))
            .get();
    // 批量预取例外与完成记录（此前逐任务逐日查库 = N×D 次查询，
    // 重复任务多时智能清单卡顿；与日历 getCalendarItems 预取模式一致）
    final taskIds = rows.map((t) => t.id).toList();
    final exMap = await getExceptionsForTasks(taskIds);
    final doneSet = await getCompletedSetForTasks(taskIds, start, end);
    final result = <Task>[];
    for (final t in rows) {
      if (t.parentId != null) continue; // 子任务不进智能清单
      if (t.completedAt != null) continue;
      if (t.rrule.isNotEmpty) {
        // 批量展开窗口内实例 + 内存过滤（与日历 getCalendarItems 同模式），
        // 替代逐日 while 循环逐日 expandTaskForDateWith。
        // 候选日 = 规则实例 + 例外改期目标日（目标日可能不是规则命中日）
        final exList = exMap[t.id] ?? const [];
        final skippedDays = decodeSkippedDays(t);
        final dayCandidates = <DateTime>[
          for (final inst in RruleService.instance.expand(
            t.planStart ?? t.createdAt,
            t.rrule,
            from: start,
            to: end,
            limit: 2000,
          ))
            AppClock.at(inst.year, inst.month, inst.day),
        ];
        for (final ex in exList) {
          final od = ex.overrideScheduledDate;
          if (ex.action != 'edit' || od == null) continue;
          final a = AppClock.asApp(od);
          final odDay = AppClock.at(a.year, a.month, a.day);
          if (odDay.isBefore(start) || !odDay.isBefore(end)) continue;
          if (!dayCandidates.any((d) => du.DateUtilsEx.sameDay(d, odDay))) {
            dayCandidates.add(odDay);
          }
        }
        dayCandidates.sort();
        for (final instDay in dayCandidates) {
          // expand 的 to 含当天，与原 while (day.isBefore(end)) 排他口径对齐
          if (instDay.isBefore(start) || !instDay.isBefore(end)) continue;
          if (!hasInstanceOnDaySync(t, instDay, exList, skippedDays)) continue;
          if (!doneSet.contains(_doneKey(t.id, instDay))) {
            result.add(t);
            break;
          }
        }
        continue;
      }
      result.add(t);
    }
    return result;
  }

  /// 批量预取例外：一次 IN 查询返回 {taskId: [例外]}。
  /// 与 getCalendarItems 预取模式同源（例外表通常很小，全量预取）。
  /// 防空：ids 为空直接返回空 map（drift isIn([]) 会生成非法 SQL）。
  Future<Map<int, List<TaskException>>> getExceptionsForTasks(
    List<int> ids,
  ) async {
    if (ids.isEmpty) return {};
    final rows = await (select(
      taskExceptions,
    )..where((e) => e.taskId.isIn(ids))).get();
    final map = <int, List<TaskException>>{};
    for (final ex in rows) {
      map.putIfAbsent(ex.taskId, () => []).add(ex);
    }
    return map;
  }

  /// 批量预取完成记录：一次 IN + 日期范围查询（[to] 排他，内部 +1 天），
  /// 返回 'taskId_年_月_日' 集合（与 isInstanceCompleted 的 00:00 基准一致）。
  /// 防空同 getExceptionsForTasks。
  Future<Set<String>> getCompletedSetForTasks(
    List<int> ids,
    DateTime from,
    DateTime to,
  ) async {
    if (ids.isEmpty) return {};
    final start = AppClock.at(from.year, from.month, from.day);
    final end = AppClock.nextDay(to);
    final rows =
        await (select(taskCompletions)..where(
              (c) =>
                  c.taskId.isIn(ids) &
                  c.instanceDate.isBiggerOrEqualValue(start) &
                  c.instanceDate.isSmallerThanValue(end),
            ))
            .get();
    return {for (final c in rows) _doneKey(c.taskId, c.instanceDate)};
  }

  /// 完成记录集合的 key：与 getCalendarItems 的 doneSet 同格式。
  /// DB 读回值为系统时区解释，取字段前必须按应用时区重新解释，
  /// 否则与写入侧（应用时区 00:00 基准）key 不一致，完成状态错位。
  static String _doneKey(int taskId, DateTime d) {
    final a = AppClock.asApp(d);
    return '${taskId}_${a.year}_${a.month}_${a.day}';
  }

  /// 全量任务（含已完成/子任务/清单内全部）——专注详情等页面
  /// 需要按 taskId 反查标题时使用（不能只取未完成任务）
  Future<List<Task>> getAllTasks() => select(tasks).get();

  /// 智能清单：全部（未完成，不含子任务；排除已结束的有限重复系列）
  Future<List<Task>> getAllUncompleted() async {
    final rows = await select(tasks).get();
    final result = rows.where((t) => t.parentId == null && !isCompleted(t));
    final active = <Task>[];
    for (final t in result) {
      // COUNT/UNTIL 已耗尽的系列不再出现在活动视图（也不排提醒）
      if (t.rrule.isNotEmpty && !await hasFutureInstances(t)) continue;
      active.add(t);
    }
    return active;
  }

  /// 重复系列是否还有未来实例（COUNT/UNTIL 未耗尽；非重复恒为 true）
  Future<bool> hasFutureInstances(Task t) async {
    if (t.rrule.isEmpty) return true;
    final base = t.planStart ?? t.createdAt;
    final now = AppClock.now();
    // 窗口至少覆盖一个完整周期——长间隔任务（如每 2 年）
    // 固定 370 天窗口内无实例会被误判"系列结束"，数据从视图消失
    final hits = RruleService.instance.expand(
      base,
      t.rrule,
      from: now,
      to: AppClock.addCalendarDays(
        now,
        RruleService.windowDaysFor(t.rrule),
      ),
      limit: 1,
    );
    return hits.isNotEmpty;
  }

  /// 智能清单：已完成（限量，不含子任务）
  /// 5.2：重复任务"今天已完成"也进入已完成视图（实例级完成语义），
  /// 排序按实际完成时间（预取今日实例完成记录）
  Future<List<Task>> getCompletedTasks({int limit = 200}) async {
    final rows = await select(tasks).get();
    final now = AppClock.now();
    final today = AppClock.at(now.year, now.month, now.day);
    // 预取今日重复实例完成时间（排序用）
    final todayCompletions = await (select(
      taskCompletions,
    )..where((c) => c.instanceDate.equals(today))).get();
    final completedAtByTask = {
      for (final c in todayCompletions) c.taskId: c.completedAt,
    };
    final done = <Task>[];
    for (final t in rows) {
      if (t.parentId != null) continue;
      if (t.rrule.isEmpty) {
        if (t.completedAt != null) done.add(t);
      } else {
        // 重复任务"今天已完成"直接用已预取的今日完成记录判断
        //（此前逐任务 isInstanceCompleted 再查一次库）
        if (completedAtByTask.containsKey(t.id)) done.add(t);
      }
    }
    done.sort(
      (a, b) => (b.completedAt ?? completedAtByTask[b.id] ?? b.createdAt)
          .compareTo(a.completedAt ?? completedAtByTask[a.id] ?? a.createdAt),
    );
    return done.take(limit).toList();
  }

  /// 任务是否完成（重复任务按实例判断）
  bool isCompleted(Task t) {
    if (t.rrule.isNotEmpty) return false;
    return t.completedAt != null;
  }

  /// 重复任务某实例是否完成（limit 1 容错：脏数据存在重复行也不崩）
  /// 实例日期归一化到当天 00:00（与完成记录存储基准一致）
  Future<bool> isInstanceCompleted(int taskId, DateTime instanceDate) async {
    final day = du.DateUtilsEx.normalizeInstanceDate(instanceDate);
    final found =
        await (select(taskCompletions)
              ..where(
                (t) => t.taskId.equals(taskId) & t.instanceDate.equals(day),
              )
              ..limit(1))
            .getSingleOrNull();
    return found != null;
  }

  /// 重复任务：完成实例（幂等：已存在同实例则更新完成时间，不重复插入）
  /// 实例日期归一化到当天 00:00，避免同一实例产生多条不同时刻的记录
  Future<void> completeInstance(int taskId, DateTime instanceDate) async {
    final day = du.DateUtilsEx.normalizeInstanceDate(instanceDate);
    final existing =
        await (select(taskCompletions)
              ..where(
                (t) => t.taskId.equals(taskId) & t.instanceDate.equals(day),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) {
      await (update(taskCompletions)..where((t) => t.id.equals(existing.id)))
          .write(TaskCompletionsCompanion(completedAt: Value(AppClock.now())));
    } else {
      await into(taskCompletions).insert(
        TaskCompletionsCompanion.insert(
          taskId: taskId,
          instanceDate: day,
          completedAt: AppClock.now(),
        ),
      );
    }
  }

  /// 命中校验的实例完成——重复任务只允许在"规则命中日"或
  /// "例外改期目标日"写入完成记录，防止非命中日产生孤儿完成记录
  ///（此前命中检查散落在 UI 层，控制器/DB 无统一约束）。
  /// 非重复任务走普通完成（completedAt）；重复任务返回 false = 未命中（未写入）。
  Future<bool> completeInstanceIfHit(int taskId, DateTime instanceDate) async {
    final t = await getTask(taskId);
    if (t == null) return false;
    if (t.rrule.isEmpty) {
      await completeTask(taskId);
      return true;
    }
    final day = du.DateUtilsEx.normalizeInstanceDate(instanceDate);
    final hit = await expandTaskForDate(t, day);
    if (hit.isEmpty) return false;
    await completeInstance(taskId, day);
    return true;
  }

  /// 重复任务：撤销实例完成（归一化）
  Future<void> uncompleteInstance(int taskId, DateTime instanceDate) async {
    final day = du.DateUtilsEx.normalizeInstanceDate(instanceDate);
    await (delete(
      taskCompletions,
    )..where((t) => t.taskId.equals(taskId) & t.instanceDate.equals(day))).go();
  }

  /// 查询单条实例完成记录（跳过实例时暂存完成时间，撤销时恢复）
  Future<TaskCompletion?> getInstanceCompletion(
    int taskId,
    DateTime instanceDate,
  ) async {
    final day = du.DateUtilsEx.normalizeInstanceDate(instanceDate);
    return (select(taskCompletions)
          ..where((t) => t.taskId.equals(taskId) & t.instanceDate.equals(day))
          ..limit(1))
        .getSingleOrNull();
  }

  /// 恢复实例完成记录（幂等：已存在则更新完成时间，不重复插入）
  Future<void> restoreInstanceCompletion(
    int taskId,
    DateTime instanceDate,
    DateTime completedAt,
  ) async {
    final day = du.DateUtilsEx.normalizeInstanceDate(instanceDate);
    final existing = await getInstanceCompletion(taskId, day);
    if (existing != null) {
      await (update(taskCompletions)..where((t) => t.id.equals(existing.id)))
          .write(TaskCompletionsCompanion(completedAt: Value(completedAt)));
    } else {
      await into(taskCompletions).insert(
        TaskCompletionsCompanion.insert(
          taskId: taskId,
          instanceDate: day,
          completedAt: completedAt,
        ),
      );
    }
  }

  /// 系列改期后清理旧完成记录：删除该任务所有不再匹配新系列展开结果的
  /// 完成记录（如改期前挂在旧日期上的实例）。返回被删除的记录（撤销恢复用）。
  /// 过去已发生的实例只要仍被新规则命中就保留（避免清空历史完成记录）。
  Future<List<TaskCompletion>> pruneCompletionsForTask(
    int taskId,
    DateTime newStart,
    String rrule,
  ) async {
    if (rrule.isEmpty) return const [];
    final now = AppClock.now();
    final today = AppClock.at(now.year, now.month, now.day);
    // 从 newStart 全量展开（含过去）：过去命中新规则的日期保留完成记录
    final instances = RruleService.instance.expand(
      newStart,
      rrule,
      to: AppClock.addCalendarDays(today, 93),
      limit: 5000,
    );
    if (instances.isEmpty) return const []; // 展开失败则保守不清理
    final keepDays = instances
        .map((d) => AppClock.at(d.year, d.month, d.day).millisecondsSinceEpoch)
        .toSet();
    // 例外改期日期同样保留（其上的完成记录合法）
    final exceptions = await (select(
      taskExceptions,
    )..where((e) => e.taskId.equals(taskId))).get();
    for (final ex in exceptions) {
      final od = ex.overrideScheduledDate;
      if (od != null) {
        // ：DB 读回值为系统时区字段，取字段前按应用时区解释
        final a = AppClock.asApp(od);
        keepDays.add(
          AppClock.at(a.year, a.month, a.day).millisecondsSinceEpoch,
        );
      }
    }
    final all = await (select(
      taskCompletions,
    )..where((c) => c.taskId.equals(taskId))).get();
    final removed = <TaskCompletion>[];
    for (final c in all) {
      // ：DB 读回值为系统时区字段，取字段前按应用时区解释
      final a = AppClock.asApp(c.instanceDate);
      final d = AppClock.at(a.year, a.month, a.day);
      if (!keepDays.contains(d.millisecondsSinceEpoch)) {
        await (delete(taskCompletions)..where((t) => t.id.equals(c.id))).go();
        removed.add(c);
      }
    }
    return removed;
  }

  Future<int> insertTask(TasksCompanion t) => into(tasks).insert(t);

  /// 修改/清除重复规则统一收口：
  /// - 清除重复（newRrule 为空）：删除全部实例完成记录与例外（重复实例语义失效，
  ///   避免旧完成记录继续参与统计、旧例外继续影响展开）
  /// - 更换规则：清理不再匹配新系列的完成记录（过去仍命中新规则的实例保留），
  ///   并移除例外实例日不再命中新规则的例外记录
  /// 返回被删除的完成记录与例外（供撤销恢复，任务页改期撤销时
  /// 恢复原锚点数据，与日历系列改期撤销 undoMoveTaskSeries 行为一致）。
  Future<RecurringChangeResult> applyRecurringChange(
    int taskId, {
    required String oldRrule,
    required String newRrule,
    DateTime? newStart,
  }) async {
    if (newRrule.isEmpty) {
      if (oldRrule.isEmpty) return const RecurringChangeResult();
      final removed = await (select(
        taskCompletions,
      )..where((c) => c.taskId.equals(taskId))).get();
      final removedEx = await (select(
        taskExceptions,
      )..where((e) => e.taskId.equals(taskId))).get();
      await (delete(
        taskCompletions,
      )..where((c) => c.taskId.equals(taskId))).go();
      await (delete(
        taskExceptions,
      )..where((e) => e.taskId.equals(taskId))).go();
      return RecurringChangeResult(
        removedCompletions: removed,
        removedExceptions: removedEx,
      );
    }
    if (oldRrule.isEmpty) return const RecurringChangeResult();
    final t = await getTask(taskId);
    final start = newStart ?? t?.planStart;
    if (start == null) return const RecurringChangeResult();
    final removed = await pruneCompletionsForTask(taskId, start, newRrule);
    final exceptions = await (select(
      taskExceptions,
    )..where((e) => e.taskId.equals(taskId))).get();
    final removedEx = <TaskException>[];
    for (final ex in exceptions) {
      final hit = RruleService.instance.hitsOn(
        newRrule,
        start,
        du.DateUtilsEx.normalizeInstanceDate(ex.instanceDate),
      );
      if (!hit) {
        removedEx.add(ex);
        await (delete(taskExceptions)..where((x) => x.id.equals(ex.id))).go();
      }
    }
    return RecurringChangeResult(
      removedCompletions: removed,
      removedExceptions: removedEx,
    );
  }

  Future<void> updateTask(int id, TasksCompanion t) =>
      (update(tasks)..where((t) => t.id.equals(id))).write(t);

  Future<Task?> getTask(int id) =>
      (select(tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 递归删除任务（含子任务）
  Future<void> deleteTask(int taskId) => _deleteTaskRecursive(taskId);

  /// 撤销删除：按原 ID 恢复任务（D1）
  Future<void> restoreTask(Task t) => into(tasks).insertOnConflictUpdate(
    TasksCompanion(
      id: Value(t.id),
      listId: Value(t.listId),
      parentId: t.parentId == null ? const Value(null) : Value(t.parentId),
      title: Value(t.title),
      note: Value(t.note),
      quadrant: Value(t.quadrant),
      planStart: t.planStart == null ? const Value(null) : Value(t.planStart),
      planEnd: t.planEnd == null ? const Value(null) : Value(t.planEnd),
      dueTime: t.dueTime == null ? const Value(null) : Value(t.dueTime),
      isAllDay: Value(t.isAllDay),
      rrule: Value(t.rrule),
      color: Value(t.color),
      hasReminder: Value(t.hasReminder),
      hasNote: Value(t.hasNote),
      sortOrder: Value(t.sortOrder),
      skippedDates: Value(t.skippedDates),
      completedAt: t.completedAt == null
          ? const Value(null)
          : Value(t.completedAt),
      createdAt: Value(t.createdAt),
    ),
  );

  /// 完成任务（非重复）
  Future<void> completeTask(int id) =>
      (update(tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(completedAt: Value(AppClock.now())),
      );

  /// 恢复任务（非重复）
  Future<void> reopenTask(int id) =>
      (update(tasks)..where((t) => t.id.equals(id))).write(
        const TasksCompanion(completedAt: Value(null)),
      );

  /// 子任务"今天完成"？（重复任务看今日实例，非重复看 completedAt）
  Future<bool> _childDoneToday(Task c) async {
    final now = AppClock.now();
    final today = AppClock.at(now.year, now.month, now.day);
    if (c.rrule.isNotEmpty) return isInstanceCompleted(c.id, today);
    return c.completedAt != null;
  }

  /// 今日对齐联动：所有子任务"今天完成" → 父任务"今天完成"
  /// （重复父任务写今日实例；非重复父任务写 completedAt，已"今天完成"则幂等跳过）
  Future<void> maybeAutoCompleteParent(int parentId) async {
    final parent = await getTask(parentId);
    if (parent == null) return;
    final children = await getSubTasks(parentId);
    if (children.isEmpty) return;
    for (final c in children) {
      if (!await _childDoneToday(c)) return;
    }
    final now = AppClock.now();
    final today = AppClock.at(now.year, now.month, now.day);
    if (parent.rrule.isNotEmpty) {
      if (!await isInstanceCompleted(parentId, today)) {
        await completeInstance(parentId, today);
      }
    } else if (parent.completedAt == null) {
      await completeTask(parentId);
    }
  }

  /// 反向联动：父任务"今天已完成"且存在子任务今天未完成 →
  /// 父任务恢复未完成（重复父任务撤销今日实例；非重复父任务清 completedAt）
  Future<void> maybeReopenParent(int parentId) async {
    final parent = await getTask(parentId);
    if (parent == null) return;
    final now = AppClock.now();
    final today = AppClock.at(now.year, now.month, now.day);
    final parentDone = parent.rrule.isNotEmpty
        ? await isInstanceCompleted(parentId, today)
        : parent.completedAt != null;
    if (!parentDone) return; // 父任务本来就未完成，无需恢复
    final children = await getSubTasks(parentId);
    if (children.isEmpty) return;
    for (final c in children) {
      if (!await _childDoneToday(c)) {
        if (parent.rrule.isNotEmpty) {
          await uncompleteInstance(parentId, today);
        } else {
          await reopenTask(parentId);
        }
        return;
      }
    }
  }

  /// 搜索：全字段模糊
  Future<List<Task>> searchTasks(String query) async {
    final q = '%$query%';
    final rows = await (select(
      tasks,
    )..where((t) => t.title.like(q) | t.note.like(q))).get();
    return rows.where((t) => !isCompleted(t)).toList();
  }

  /// 批量完成/删除/移动
  Future<void> batchComplete(List<int> ids) async {
    for (final id in ids) {
      await completeTask(id);
    }
  }

  Future<void> batchDelete(List<int> ids) async {
    for (final id in ids) {
      await _deleteTaskRecursive(id);
    }
  }

  Future<void> batchMove(List<int> ids, int targetListId) async {
    await transaction(() async {
      for (final id in ids) {
        await (update(tasks)..where((t) => t.id.equals(id))).write(
          TasksCompanion(listId: Value(targetListId)),
        );
      }
    });
  }

  /// 日历：某日期范围内所有任务（含重复任务实例展开 + 跨天任务覆盖多日，限定 3 个月）
  /// 预取 exceptions/completions 批量判断，避免逐日逐任务查库（手机端卡顿修复）
  Future<List<CalendarItem>> getCalendarItems(
    DateTime from,
    DateTime to,
  ) async {
    final start = AppClock.at(from.year, from.month, from.day);
    final end = AppClock.nextDay(to);
    final listIds = await getVisibleCalendarListIds();
    // 防空：全部清单都从日历隐藏时 listIds 为空，
    // isIn([]) 会生成非法 SQL（IN ()）——直接返回空
    if (listIds.isEmpty) return const [];
    final tasksAll = await (select(
      tasks,
    )..where((t) => t.listId.isIn(listIds))).get();
    final allLists = await getAllLists();
    final listById = {for (final l in allLists) l.id: l};

    // 预取：任务 → 例外列表（避免 expandTaskForDateWith 每次查库）
    final taskIds = tasksAll.map((t) => t.id).toList();
    final exceptionsAll = await (select(
      taskExceptions,
    )..where((e) => e.taskId.isIn(taskIds))).get();
    final exceptionsByTask = <int, List<TaskException>>{};
    for (final ex in exceptionsAll) {
      exceptionsByTask.putIfAbsent(ex.taskId, () => []).add(ex);
    }
    // 预取：窗口内已完成实例（避免逐实例查库）
    final completions =
        await (select(taskCompletions)..where(
              (c) =>
                  c.taskId.isIn(taskIds) &
                  c.instanceDate.isBiggerOrEqualValue(start) &
                  c.instanceDate.isSmallerThanValue(end),
            ))
            .get();
    final doneSet = <String>{
      // ：DB 读回值取字段前按应用时区解释（与 _doneKey 同口径）
      for (final c in completions) _doneKey(c.taskId, c.instanceDate),
    };

    final items = <CalendarItem>[];
    for (final t in tasksAll) {
      if (t.parentId != null) continue;
      final listColor = listById[t.listId]?.color ?? '#4F8EF7';
      if (t.rrule.isEmpty) {
        // 非重复任务：计划区间覆盖窗口内的每一天（跨天任务多日显示）
        final ps = t.planStart;
        if (ps == null) {
          // 仅截止时间的任务 → 在截止日展示一个实例
          final due = t.dueTime;
          if (due == null) continue;
          // ：DB 读回值为系统时区字段，取字段前按应用时区解释
          final a = AppClock.asApp(due);
          final dueDay = AppClock.at(a.year, a.month, a.day);
          if (!dueDay.isBefore(start) && dueDay.isBefore(end)) {
            items.add(
              CalendarItem(
                task: t,
                instanceDate: dueDay,
                completed: t.completedAt != null,
                listColor: listColor,
              ),
            );
          }
          continue;
        }
        final pe = t.planEnd ?? ps.add(const Duration(hours: 1));
        // ：DB 读回值为系统时区字段，取字段前按应用时区解释
        final pa = AppClock.asApp(ps);
        var d = AppClock.at(pa.year, pa.month, pa.day);
        while (d.isBefore(end) && d.isBefore(pe)) {
          if (!d.isBefore(start)) {
            items.add(
              CalendarItem(
                task: t,
                instanceDate: d,
                completed: t.completedAt != null,
                listColor: listColor,
              ),
            );
          }
          d = AppClock.addCalendarDays(d, 1);
        }
        continue;
      }
      // 重复任务：按规则批量展开窗口内实例，再内存过滤跳过/例外/完成状态。
      // 此前逐日 while 循环逐日调 expandTaskForDateWith，每次重新
      // jsonDecode(skippedDates) + 线性扫描，无限期任务历史实例极多时卡顿
      final exList = exceptionsByTask[t.id] ?? const [];
      final skippedDays = decodeSkippedDays(t);
      // 候选日 = 规则实例 + 例外改期目标日（目标日可能不是规则命中日，
      // 逐日扫描口径下同样显示；批量展开需手动并入）
      final dayCandidates = <DateTime>[
        for (final inst in RruleService.instance.expand(
          t.planStart ?? t.createdAt,
          t.rrule,
          from: start,
          to: end,
          limit: 2000,
        ))
          AppClock.at(inst.year, inst.month, inst.day),
      ];
      for (final ex in exList) {
        final od = ex.overrideScheduledDate;
        if (ex.action != 'edit' || od == null) continue;
        final a = AppClock.asApp(od);
        final odDay = AppClock.at(a.year, a.month, a.day);
        if (odDay.isBefore(start) || !odDay.isBefore(end)) continue;
        if (!dayCandidates.any((d) => du.DateUtilsEx.sameDay(d, odDay))) {
          dayCandidates.add(odDay);
        }
      }
      dayCandidates.sort();
      for (final dayStart in dayCandidates) {
        // expand 的 to 含当天，需与原 while (day.isBefore(end)) 排他口径对齐
        if (dayStart.isBefore(start) || !dayStart.isBefore(end)) continue;
        if (!hasInstanceOnDaySync(t, dayStart, exList, skippedDays)) continue;
        // 例外改期到当天的实例 → 携带目标时刻（带时分），
        // 时间轴据此渲染位置（此前所有实例统一 00:00，改期时分不生效）
        DateTime? displayTime;
        for (final ex in exList) {
          final od = ex.overrideScheduledDate;
          if (ex.action == 'edit' &&
              od != null &&
              du.DateUtilsEx.sameDay(od, dayStart)) {
            displayTime = od;
            break;
          }
        }
        final doneKey = _doneKey(t.id, dayStart);
        items.add(
          CalendarItem(
            task: t,
            instanceDate: dayStart,
            completed: doneSet.contains(doneKey),
            listColor: listColor,
            displayTime: displayTime,
          ),
        );
        // 跨天覆盖：实例延续到 planEnd 所在日，该日也生成条目
        //（与非重复任务的跨天覆盖一致；命中日被跳过则整实例不显示）。
        // 全天任务不参与：planEnd=次日 00:00 是"全天占位"标记，若按跨天
        // 覆盖会把每个实例再铺到次日，置顶区同一实例显示两天/一天两个块
        final ps = t.planStart;
        if (ps != null && !t.isAllDay) {
          final pe = t.planEnd ?? ps.add(const Duration(hours: 1));
          final psA = AppClock.asApp(ps);
          final peA = AppClock.asApp(pe);
          final spanDays = AppClock.daysBetween(psA, peA);
          for (var i = 1; i <= spanDays; i++) {
            final coverDay = AppClock.addCalendarDays(dayStart, i);
            if (coverDay.isBefore(start) || !coverDay.isBefore(end)) {
              continue;
            }
            items.add(
              CalendarItem(
                task: t,
                instanceDate: coverDay,
                completed: doneSet.contains(doneKey),
                listColor: listColor,
              ),
            );
          }
        }
      }
    }
    return items;
  }

  /// 存量数据修复：重复任务的 planStart 若不被规则命中（旧逻辑创建的数据，
  /// 如规则为周二周三但开始日期是周一），自动吸附到距锚点最近的命中日。
  /// 在启动时调用（不改变 rrule，只修正锚点日期，保持时分）。
  /// A13：与创建/改规则路径统一用 nearestHitOnOrNear（吸附含过去一侧），
  /// 此前 firstHitOnOrAfter 只向未来吸附，当前周窗口可能无实例。
  Future<void> fixOrphanRecurringAnchors() async {
    final rows = await (select(
      tasks,
    )..where((t) => t.rrule.isNotValue(''))).get();
    for (final t in rows) {
      final ps = t.planStart;
      if (ps == null) continue;
      final newStart = RruleService.instance.normalizeAnchor(ps, t.rrule);
      if (newStart == null) continue;
      final pe = t.planEnd;
      final newEnd = pe == null
          ? newStart.add(const Duration(hours: 1))
          : newStart.add(pe.difference(ps));
      await (update(tasks)..where((x) => x.id.equals(t.id))).write(
        TasksCompanion(planStart: Value(newStart), planEnd: Value(newEnd)),
      );
    }
  }

  /// 迁移辅助：旧列值可能是 unix 秒（int）或 ISO 字符串
  DateTime? _migrateDateTime(Object? raw) {
    if (raw == null) return null;
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw * 1000);
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
    }
    if (raw is String) {
      final v = int.tryParse(raw);
      if (v != null) {
        return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      }
      return DateTime.tryParse(raw);
    }
    return null;
  }

  /// 判断重复任务在某日是否有实例
  Future<List<Task>> expandTaskForDate(Task t, DateTime date) async {
    final exceptions = await (select(
      taskExceptions,
    )..where((e) => e.taskId.equals(t.id))).get();
    return expandTaskForDateWith(t, date, exceptions);
  }

  /// 判断任务在某日是否有实例（exceptions 由调用方传入，避免日历批量查询重复查库）
  Future<List<Task>> expandTaskForDateWith(
    Task t,
    DateTime date,
    List<TaskException> exceptions,
  ) async {
    return hasInstanceOnDaySync(t, date, exceptions, null) ? [t] : const [];
  }

  /// 预解码 skippedDates JSON 为"日期 key 集合"（key = 应用时区 y-m-d）。
  /// 批量循环（日历逐日/排期窗口/下次实例）在任务级解码一次，避免
  /// expandTaskForDateWith 每次 jsonDecode + 线性扫描——无限期任务跳过
  /// 实例极多时是主要 CPU 开销。损坏 JSON 返回 null（按无跳过处理，
  /// 与原有静默容错行为一致）。
  Set<String>? decodeSkippedDays(Task t) {
    if (t.skippedDates.isEmpty) return const <String>{};
    try {
      final list = jsonDecode(t.skippedDates) as List;
      final result = <String>{};
      for (final e in list) {
        // 与 DateUtilsEx.sameDay 同口径：先按应用时区解释再取日期字段
        final a = AppClock.asApp(DateTime.parse(e as String));
        result.add('${a.year}-${a.month}-${a.day}');
      }
      return result;
    } catch (_) {
      // 非法 JSON（损坏备份导入）静默视为无跳过
      return null;
    }
  }

  static String _dayKeyStr(DateTime day) {
    final a = AppClock.asApp(day);
    return '${a.year}-${a.month}-${a.day}';
  }

  /// 判断任务在某日是否有实例的同步纯内存版本（无 DB 查询）。
  /// [skippedDays] 为 decodeSkippedDays 的预解码结果；传 null 时按需解码。
  /// 非重复任务按计划区间覆盖判断；重复任务依次检查跳过/例外/规则命中，
  /// 语义与 expandTaskForDateWith 完全一致。供日历/智能清单/排期窗口等
  /// 批量循环替代逐日 async 查询，消除异步切换与重复 JSON 解码开销。
  bool hasInstanceOnDaySync(
    Task t,
    DateTime date,
    List<TaskException> exceptions,
    Set<String>? skippedDays,
  ) {
    // ：date 可能是循环 day（应用时区）或外部传入值，统一按应用时区
    // 解释后再取字段（asApp 对已是应用时区的 TZDateTime 幂等）
    final da = AppClock.asApp(date);
    if (t.rrule.isEmpty) {
      // 非重复任务：判断该天是否被计划区间覆盖（含跨天）
      final ps = t.planStart;
      if (ps == null) return false;
      final pe = t.planEnd ?? ps.add(const Duration(hours: 1));
      final dayStart = AppClock.at(da.year, da.month, da.day);
      final dayEnd = AppClock.nextDay(dayStart);
      return ps.isBefore(dayEnd) && pe.isAfter(dayStart);
    }
    final dateKey = AppClock.at(da.year, da.month, da.day);
    final days = skippedDays ?? decodeSkippedDays(t);
    if (days != null && days.contains(_dayKeyStr(dateKey))) {
      return false;
    }
    for (final ex in exceptions) {
      final od = ex.overrideScheduledDate;
      // 例外改期：overrideScheduledDate 指向的日期视为有实例（原日期不再显示）
      // ：例外为 DB 读回值，字段按应用时区解释后比较
      if (ex.action == 'edit' &&
          od != null &&
          du.DateUtilsEx.sameDay(od, dateKey)) {
        return true;
      }
      final ed = ex.instanceDate;
      if (du.DateUtilsEx.sameDay(ed, dateKey)) {
        // 例外：若 overrideScheduledDate 指向其他日期，则本日期无实例
        if (ex.action == 'edit' && od != null) {
          if (!du.DateUtilsEx.sameDay(od, dateKey)) {
            return false;
          }
        }
        if (ex.action == 'delete') return false;
        return true;
      }
    }
    // 需要判断 rrule 是否命中（调用 rrule_expander）
    final base = t.planStart ?? t.createdAt;
    return RruleService.instance.hitsOn(t.rrule, base, dateKey);
  }

  /// 完成记录集合的 key（与 getCompletedSetForTasks 返回集合同格式）。
  /// 供提醒调度等批量路径按同一口径判断实例是否已完成。
  String completionKey(int taskId, DateTime day) =>
      _doneKey(taskId, day);

  Future<List<int>> getVisibleCalendarListIds() async {
    final rows = await (select(
      lists,
    )..where((l) => l.showInCalendar.equals(true))).get();
    return rows.map((r) => r.id).toList();
  }

  // ---------- 提醒 ----------
  Future<List<Reminder>> getReminders(int taskId) =>
      (select(reminders)..where((r) => r.taskId.equals(taskId))).get();

  Future<int> insertReminder(RemindersCompanion r) => into(reminders).insert(r);

  Future<void> deleteReminder(int id) =>
      (delete(reminders)..where((r) => r.id.equals(id))).go();

  Future<void> updateTaskHasReminder(int taskId, bool value) =>
      (update(tasks)..where((t) => t.id.equals(taskId))).write(
        TasksCompanion(hasReminder: Value(value)),
      );

  // ---------- 例外 ----------
  /// 例外实例日期归一化到当天 00:00（与规则展开/完成记录基准一致）。
  /// 返回新例外记录 ID。
  Future<int> insertException(TaskExceptionsCompanion e) {
    return into(taskExceptions).insert(
      e.copyWith(
        instanceDate: Value(
          du.DateUtilsEx.normalizeInstanceDate(e.instanceDate.value),
        ),
      ),
    );
  }

  Future<List<TaskException>> getExceptions(int taskId) =>
      (select(taskExceptions)..where((t) => t.taskId.equals(taskId))).get();

  Future<void> deleteException(int id) =>
      (delete(taskExceptions)..where((t) => t.id.equals(id))).go();

  /// 按 id 查单条例外（撤销改期时读取迁移信息）
  Future<TaskException?> getException(int id) =>
      (select(taskExceptions)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> updateException(int id, DateTime toDate) =>
      (update(taskExceptions)..where((t) => t.id.equals(id))).write(
        TaskExceptionsCompanion(overrideScheduledDate: Value(toDate)),
      );

  // ---------- 习惯 ----------
  Future<List<Habit>> getHabits() async {
    final q = select(habits)..orderBy([(h) => OrderingTerm.asc(h.createdAt)]);
    return q.get();
  }

  Future<int> insertHabit(String name, String icon, DateTime? reminderTime) =>
      into(habits).insert(
        HabitsCompanion.insert(
          name: name,
          icon: Value(icon),
          reminderTime: Value(reminderTime),
          createdAt: AppClock.now(),
        ),
      );

  Future<void> deleteHabit(int id) async {
    await (delete(habitRecords)..where((h) => h.habitId.equals(id))).go();
    await (delete(habits)..where((h) => h.id.equals(id))).go();
  }

  Future<Habit?> getHabit(int id) =>
      (select(habits)..where((h) => h.id.equals(id))).getSingleOrNull();

  /// 更新习惯提醒时间（null = 取消提醒）
  Future<void> updateHabitReminder(int id, DateTime? reminderTime) =>
      (update(habits)..where((h) => h.id.equals(id))).write(
        HabitsCompanion(reminderTime: Value(reminderTime)),
      );

  Future<bool> isHabitDone(int habitId, DateTime date) async {
    // ：入参可能是 DB 读回值，统一按应用时区解释后取字段
    final a = AppClock.asApp(date);
    final d = AppClock.at(a.year, a.month, a.day);
    final found =
        await (select(habitRecords)
              ..where((h) => h.habitId.equals(habitId) & h.date.equals(d)))
            .getSingleOrNull();
    return found != null;
  }

  /// 打卡/取消（toggle 语义）。事务化——双击并发时串行执行，
  /// 第二次调用看到第一次的提交结果（查→删/插），不会并发插入重复记录
  ///（配合 habit_records 唯一索引双保险）
  Future<void> checkHabit(int habitId, DateTime date) async {
    // ：入参可能是 DB 读回值，统一按应用时区解释后取字段
    final a = AppClock.asApp(date);
    final d = AppClock.at(a.year, a.month, a.day);
    await transaction(() async {
      final existing =
          await (select(habitRecords)
                ..where((h) => h.habitId.equals(habitId) & h.date.equals(d)))
              .getSingleOrNull();
      if (existing == null) {
        await into(habitRecords).insert(
          HabitRecordsCompanion.insert(
            habitId: habitId,
            date: d,
            completedAt: AppClock.now(),
          ),
        );
      } else {
        await (delete(
          habitRecords,
        )..where((h) => h.id.equals(existing.id))).go();
      }
    });
  }

  Future<List<HabitRecord>> getHabitRecords(int habitId) =>
      (select(habitRecords)..where((h) => h.habitId.equals(habitId))).get();

  Future<List<HabitRecord>> getAllHabitRecords() => select(habitRecords).get();

  // ---------- 番茄专注 ----------
  Future<void> insertPomodoro(
    int? taskId,
    int durationMinutes,
    DateTime startedAt,
  ) => into(pomodoroRecords).insert(
    PomodoroRecordsCompanion.insert(
      taskId: Value(taskId),
      durationMinutes: durationMinutes,
      startedAt: startedAt,
      completedAt: AppClock.now(),
    ),
  );

  Future<List<PomodoroRecord>> getPomodoros({DateTime? from, DateTime? to}) {
    final q = select(pomodoroRecords)
      ..orderBy([(p) => OrderingTerm.desc(p.completedAt)]);
    if (from != null) {
      q.where((p) => p.completedAt.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      // 与 getCompletedCountByDay 口径一致——to 排他 + 内部 +1 天，
      // 否则统计页传"周日/月末/12-31 00:00"时当天记录全部漏计
      final end = AppClock.nextDay(to);
      q.where((p) => p.completedAt.isSmallerThanValue(end));
    }
    return q.get();
  }

  // ---------- 设置 ----------
  Future<String?> getSetting(String key) async {
    final row = await (select(
      settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) async {
    await into(
      settings,
    ).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));
  }

  // ---------- 统计 ----------
  /// 完成率：完成数按任务所属日统计（与计划数同口径，保证每日 完成数 ≤ 计划数）：
  /// - 重复任务实例：按实例日（instanceDate = 该实例的计划日）计入，
  ///   补做/提前完成不按实际完成时刻归日；
  /// - 非重复任务：按计划开始日计入；无计划开始按截止日计入；
  /// - 无计划时间的任务（无 planStart 且无 dueTime）与子任务不计入
  ///   （与 getPlannedCountByDay 的归日口径一致）。
  Future<Map<DateTime, int>> getCompletedCountByDay(
    DateTime from,
    DateTime to,
  ) async {
    final start = AppClock.at(from.year, from.month, from.day);
    final end = AppClock.nextDay(to);
    final result = <DateTime, int>{};

    void add(DateTime d) {
      // ：d 可能是 DB 读回值（instanceDate/planStart/dueTime），统一按
      // 应用时区解释后取字段分组
      final a = AppClock.asApp(d);
      final key = AppClock.at(a.year, a.month, a.day);
      if (!key.isBefore(start) && key.isBefore(end)) {
        result[key] = (result[key] ?? 0) + 1;
      }
    }

    // 重复任务实例完成（task_completions）：按实例日（计划日）计入
    final completions = await (select(taskCompletions)..where(
          (c) =>
              c.instanceDate.isBiggerOrEqualValue(start) &
              c.instanceDate.isSmallerThanValue(end),
        ))
        .get();
    // 与计划数口径一致——仅计顶层任务，子任务不计入完成数
    // （重复子任务的实例完成记录也需过滤）
    final completionTaskIds = completions.map((c) => c.taskId).toSet();
    final topLevelTaskIds = <int>{};
    if (completionTaskIds.isNotEmpty) {
      final taskRows = await (select(
        tasks,
      )..where((t) => t.id.isIn(completionTaskIds))).get();
      for (final r in taskRows) {
        if (r.parentId == null) topLevelTaskIds.add(r.id);
      }
    }
    for (final c in completions) {
      if (!topLevelTaskIds.contains(c.taskId)) continue;
      add(c.instanceDate);
    }

    // 非重复任务完成（completedAt，rrule 为空）：按计划开始日/截止日计入，
    // 排除子任务；无计划时间的任务与计划数口径一致，不计入
    final doneTasks = await (select(tasks)..where(
          (t) =>
              t.completedAt.isNotNull() &
              t.rrule.equals('') &
              t.parentId.isNull(),
        ))
        .get();
    for (final t in doneTasks) {
      final day = t.planStart ?? t.dueTime;
      if (day == null) continue;
      add(day);
    }
    return result;
  }

  /// 每天计划的任务数（顶层、未完成+已完成合计，按计划日）
  /// 口径：计划开始日在窗口内（普通任务）+ 截止日在窗口内（仅 dueTime 的任务）
  /// + 重复任务按实例展开窗口内命中日期
  Future<Map<DateTime, int>> getPlannedCountByDay(
    DateTime from,
    DateTime to,
  ) async {
    final start = AppClock.at(from.year, from.month, from.day);
    final end = AppClock.nextDay(to);
    final result = <DateTime, int>{};

    void add(DateTime d) {
      // ：d 可能是 DB 读回值（planStart/dueTime），统一按应用时区
      // 解释后取字段分组
      final a = AppClock.asApp(d);
      final key = AppClock.at(a.year, a.month, a.day);
      result[key] = (result[key] ?? 0) + 1;
    }

    // 1) 计划开始日在窗口内的任务（原口径）
    final rows =
        await (select(tasks)..where(
              (t) =>
                  t.planStart.isBiggerOrEqualValue(start) &
                  t.planStart.isSmallerThanValue(end) &
                  t.parentId.isNull(),
            ))
            .get();
    for (final t in rows) {
      add(t.planStart!);
    }
    // 2) 无计划开始、仅截止日期的任务：按截止日计
    final dueRows =
        await (select(tasks)..where(
              (t) =>
                  t.planStart.isNull() &
                  t.dueTime.isBiggerOrEqualValue(start) &
                  t.dueTime.isSmallerThanValue(end) &
                  t.parentId.isNull(),
            ))
            .get();
    for (final t in dueRows) {
      add(t.dueTime!);
    }
    // 3) 重复任务：展开窗口内命中的实例
    final recRows =
        await (select(tasks)..where(
              (t) =>
                  t.rrule.isNotValue('') &
                  (t.planStart.isNull() | t.planStart.isSmallerThanValue(end)) &
                  t.parentId.isNull(),
            ))
            .get();
    // 批量预取例外（此前逐任务逐日查库 = N×D 次，统计月/年视图
    // 在重复任务多时秒级假死）
    final exMap = await getExceptionsForTasks(
      recRows.map((t) => t.id).toList(),
    );
    for (final t in recRows) {
      var day = start;
      while (day.isBefore(end)) {
        final hit = await expandTaskForDateWith(
          t,
          day,
          exMap[t.id] ?? const [],
        );
        if (hit.isNotEmpty) add(day);
        day = AppClock.addCalendarDays(day, 1);
      }
    }
    return result;
  }

  /// 清空已完成任务（保留未完成）
  Future<void> clearCompletedTasks() async {
    await transaction(() async {
      await delete(taskCompletions).go();
      await (update(tasks)..where((t) => t.completedAt.isNotNull())).write(
        const TasksCompanion(completedAt: Value(null)),
      );
    });
  }

  // ---------- 回收站 ----------
  Future<int> insertTrashItem(TrashItemsCompanion c) => into(trashItems).insert(c);

  /// 回收站条目（按删除时间倒序）
  Future<List<TrashItem>> getTrashItems() =>
      (select(trashItems)..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
          .get();

  Future<TrashItem?> getTrashItem(int id) =>
      (select(trashItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 按被删任务根 id 查回收站条目（撤销条撤销后删除对应行用）
  Future<TrashItem?> getTrashItemByOriginalTaskId(int originalTaskId) =>
      (select(trashItems)
            ..where((t) => t.originalTaskId.equals(originalTaskId)))
          .getSingleOrNull();

  Future<void> deleteTrashItem(int id) =>
      (delete(trashItems)..where((t) => t.id.equals(id))).go();

  Future<void> deleteTrashItemByOriginalTaskId(int originalTaskId) =>
      (delete(trashItems)
            ..where((t) => t.originalTaskId.equals(originalTaskId)))
          .go();

  Future<void> clearTrash() => delete(trashItems).go();

  /// 删除删除时间早于 [cutoff] 的回收站条目（保留期自动清理）
  Future<void> deleteTrashOlderThan(DateTime cutoff) =>
      (delete(trashItems)..where((t) => t.deletedAt.isSmallerThanValue(cutoff)))
          .go();

  /// 回收站条目数量（抽屉入口角标用）
  Future<int> countTrash() => trashItems.count().getSingle();

  // ---------- 备份支持 ----------
  Future<List<Task>> allTasksForBackup() => select(tasks).get();

  Future<List<Reminder>> allRemindersForBackup() => select(reminders).get();

  Future<List<TaskCompletion>> allCompletionsForBackup() =>
      select(taskCompletions).get();

  Future<List<TaskException>> allExceptionsForBackup() =>
      select(taskExceptions).get();

  Future<List<Setting>> allSettingsForBackup() => select(settings).get();

  // ---------- 合并导入支持（备份方案设计 3.4）----------
  /// 同名清单（limit 1——本地存在多个同名清单时合并不得崩溃，取首行）
  Future<TaskList?> getListByName(String name) =>
      (select(lists)..where((l) => l.name.equals(name))..limit(1))
          .getSingleOrNull();

  /// 同名习惯（limit 1——同上去重查询防崩溃）
  Future<Habit?> getHabitByName(String name) =>
      (select(habits)..where((h) => h.name.equals(name))..limit(1))
          .getSingleOrNull();

  /// 非子任务按（清单, 标题）查所有同名候选（合并导入指纹去重用——
  /// 同名但内容不同（计划时间/备注/重复规则等）须保留为独立任务）
  Future<List<Task>> getTasksByListAndTitle(int listId, String title) =>
      (select(tasks)..where(
            (t) =>
                t.listId.equals(listId) &
                t.parentId.isNull() &
                t.title.equals(title),
          ))
          .get();

  /// 子任务按（父任务, 标题）查所有同名候选
  Future<List<Task>> getTasksByParentAndTitle(int parentId, String title) =>
      (select(tasks)
            ..where((t) => t.parentId.equals(parentId) & t.title.equals(title)))
          .get();

  Future<Reminder?> getReminderByTriple(
    int taskId,
    int remindMinutesBefore,
    int? remindAtMinutes,
  ) =>
      (select(reminders)..where(
            (r) =>
                r.taskId.equals(taskId) &
                r.remindMinutesBefore.equals(remindMinutesBefore) &
                r.remindAtMinutes.equalsNullable(remindAtMinutes),
          )..limit(1))
          .getSingleOrNull();

  Future<TaskException?> getExceptionByTaskDateAction(
    int taskId,
    DateTime instanceDate,
    String action,
  ) =>
      (select(taskExceptions)..where(
            (e) =>
                e.taskId.equals(taskId) &
                e.instanceDate.equals(instanceDate) &
                e.action.equals(action),
          ))
          .getSingleOrNull();

  Future<HabitRecord?> getHabitRecordByDate(int habitId, DateTime date) =>
      (select(habitRecords)
            ..where((r) => r.habitId.equals(habitId) & r.date.equals(date)))
          .getSingleOrNull();

  // 合并插入（自增 ID，不保留备份旧 ID）
  Future<int> insertListFull(ListsCompanion c) => into(lists).insert(c);

  Future<int> insertTaskFull(TasksCompanion c) => into(tasks).insert(c);

  Future<int> insertReminderFull(RemindersCompanion c) =>
      into(reminders).insert(c);

  Future<int> insertCompletionFull(TaskCompletionsCompanion c) =>
      into(taskCompletions).insert(c);

  Future<int> insertExceptionFull(TaskExceptionsCompanion c) =>
      into(taskExceptions).insert(c);

  Future<int> insertHabitFull(HabitsCompanion c) => into(habits).insert(c);

  Future<int> insertHabitRecordFull(HabitRecordsCompanion c) =>
      into(habitRecords).insert(c);

  Future<int> insertPomodoroFull(PomodoroRecordsCompanion c) =>
      into(pomodoroRecords).insert(c);

  /// 全量替换（备份恢复用，原子操作）：
  /// 清空 + 逐表插入在同一个事务内，任何解析/外键/唯一约束失败自动回滚，
  /// 恢复前数据不会被部分清空。
  Future<void> replaceAll({
    required List<ListsCompanion> listRows,
    required List<TasksCompanion> taskRows,
    required List<RemindersCompanion> reminderRows,
    required List<TaskCompletionsCompanion> completionRows,
    required List<TaskExceptionsCompanion> exceptionRows,
    required List<HabitsCompanion> habitRows,
    required List<HabitRecordsCompanion> habitRecordRows,
    required List<PomodoroRecordsCompanion> pomodoroRows,
    required List<SettingsCompanion> settingRows,
  }) async {
    await transaction(() async {
      await delete(taskCompletions).go();
      await delete(taskExceptions).go();
      await delete(reminders).go();
      await delete(pomodoroRecords).go();
      await delete(habitRecords).go();
      await delete(settings).go();
      await delete(habits).go();
      await delete(tasks).go();
      await delete(lists).go();
      // 备份恢复清空回收站：避免旧快照恢复后被再次恢复成"复活任务"
      await delete(trashItems).go();
      for (final l in listRows) {
        await into(lists).insert(l, mode: InsertMode.insertOrReplace);
      }
      for (final t in taskRows) {
        await into(tasks).insert(t, mode: InsertMode.insertOrReplace);
      }
      for (final r in reminderRows) {
        await into(reminders).insert(r, mode: InsertMode.insertOrReplace);
      }
      for (final c in completionRows) {
        await into(taskCompletions).insert(c, mode: InsertMode.insertOrReplace);
      }
      for (final e in exceptionRows) {
        await into(taskExceptions).insert(e, mode: InsertMode.insertOrReplace);
      }
      for (final h in habitRows) {
        await into(habits).insert(h, mode: InsertMode.insertOrReplace);
      }
      for (final h in habitRecordRows) {
        await into(habitRecords).insert(h, mode: InsertMode.insertOrReplace);
      }
      for (final p in pomodoroRows) {
        await into(pomodoroRecords).insert(p, mode: InsertMode.insertOrReplace);
      }
      for (final s in settingRows) {
        await into(settings).insertOnConflictUpdate(s);
      }
    });
  }

  // 原始插入（备份恢复用，保留原 ID）
  Future<void> insertReminderRaw(RemindersCompanion r) =>
      into(reminders).insert(r, mode: InsertMode.insertOrReplace);

  Future<void> insertCompletionRaw(TaskCompletionsCompanion c) =>
      into(taskCompletions).insert(c, mode: InsertMode.insertOrReplace);

  Future<void> insertExceptionRaw(TaskExceptionsCompanion e) =>
      into(taskExceptions).insert(e, mode: InsertMode.insertOrReplace);

  Future<void> insertPomodoroRaw(PomodoroRecordsCompanion p) =>
      into(pomodoroRecords).insert(p, mode: InsertMode.insertOrReplace);
}

/// 重复规则变更结果：被清理的完成记录与例外（撤销恢复用，）
class RecurringChangeResult {
  final List<TaskCompletion> removedCompletions;
  final List<TaskException> removedExceptions;

  const RecurringChangeResult({
    this.removedCompletions = const [],
    this.removedExceptions = const [],
  });
}

/// 日历条目（任务 + 实例日期 + 完成状态 + 清单色）
class CalendarItem {
  final Task task;
  final DateTime instanceDate;
  final bool completed;
  final String listColor;

  /// 例外改期目标时刻（带时分）。规则实例为 null（用 planStart 时分），
  /// 例外改期到当天的实例携带目标时刻，时间轴渲染据此定位。
  final DateTime? displayTime;

  CalendarItem({
    required this.task,
    required this.instanceDate,
    required this.completed,
    required this.listColor,
    this.displayTime,
  });
}
