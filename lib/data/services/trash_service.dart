import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_json.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';

/// 已删除任务整棵树快照（任务 + 子树 + 提醒 + 完成记录 + 例外 + 番茄记录）。
/// 与回收站 `trash_items.data` 的 JSON 格式对应（编解码见本文件）。
class TrashSnapshot {
  final Task task;
  final List<Task> subTasks;
  final List<Reminder> reminders;
  final List<TaskCompletion> completions;
  final List<TaskException> exceptions;
  final List<PomodoroRecord> pomodoros;

  const TrashSnapshot({
    required this.task,
    this.subTasks = const [],
    this.reminders = const [],
    this.completions = const [],
    this.exceptions = const [],
    this.pomodoros = const [],
  });
}

/// 序列化整棵树快照（复用 backup_json 的任务域编码，schema 变化单点维护）
String encodeTrashSnapshot(TrashSnapshot snap) => jsonEncode({
  'version': 1,
  'task': taskToJson(snap.task),
  'subTasks': snap.subTasks.map(taskToJson).toList(),
  'reminders': snap.reminders.map(reminderToJson).toList(),
  'completions': snap.completions.map(completionToJson).toList(),
  'exceptions': snap.exceptions.map(exceptionToJson).toList(),
  'pomodoros': snap.pomodoros.map(pomodoroToJson).toList(),
});

/// 反序列化快照。损坏 JSON 返回 null（保守不崩溃，条目保留在回收站等待彻底删除）。
TrashSnapshot? decodeTrashSnapshot(String raw) {
  try {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return TrashSnapshot(
      task: _taskFromJson(data['task'] as Map<String, dynamic>),
      subTasks: [
        for (final e in data['subTasks'] as List)
          _taskFromJson(e as Map<String, dynamic>),
      ],
      reminders: [
        for (final e in data['reminders'] as List)
          _reminderFromJson(e as Map<String, dynamic>),
      ],
      completions: [
        for (final e in data['completions'] as List)
          _completionFromJson(e as Map<String, dynamic>),
      ],
      exceptions: [
        for (final e in data['exceptions'] as List)
          _exceptionFromJson(e as Map<String, dynamic>),
      ],
      pomodoros: [
        for (final e in data['pomodoros'] as List)
          _pomodoroFromJson(e as Map<String, dynamic>),
      ],
    );
  } catch (_) {
    return null;
  }
}

DateTime? _dt(dynamic d) => d == null ? null : DateTime.parse(d as String);

Task _taskFromJson(Map<String, dynamic> j) => Task(
  id: j['id'] as int,
  listId: j['listId'] as int,
  parentId: j['parentId'] as int?,
  title: j['title'] as String,
  note: j['note'] as String,
  quadrant: j['quadrant'] as int,
  planStart: _dt(j['planStart']),
  planEnd: _dt(j['planEnd']),
  dueTime: _dt(j['dueTime']),
  isAllDay: j['isAllDay'] as bool,
  rrule: j['rrule'] as String,
  color: j['color'] as String? ?? '',
  hasReminder: j['hasReminder'] as bool,
  hasNote: j['hasNote'] as bool,
  sortOrder: j['sortOrder'] as int,
  skippedDates: j['skippedDates'] as String,
  completedAt: _dt(j['completedAt']),
  createdAt: DateTime.parse(j['createdAt'] as String),
);

Reminder _reminderFromJson(Map<String, dynamic> j) => Reminder(
  id: j['id'] as int,
  taskId: j['taskId'] as int,
  remindMinutesBefore: j['remindMinutesBefore'] as int,
  isPersistent: j['isPersistent'] as bool,
  remindAtMinutes: j['remindAtMinutes'] as int?,
);

TaskCompletion _completionFromJson(Map<String, dynamic> j) => TaskCompletion(
  id: j['id'] as int,
  taskId: j['taskId'] as int,
  // 实例日期归一化到当天 00:00（与 DB 基准一致）
  instanceDate: DateUtilsEx.normalizeInstanceDate(
    DateTime.parse(j['instanceDate'] as String),
  ),
  completedAt: DateTime.parse(j['completedAt'] as String),
);

TaskException _exceptionFromJson(Map<String, dynamic> j) => TaskException(
  id: j['id'] as int,
  taskId: j['taskId'] as int,
  instanceDate: DateTime.parse(j['instanceDate'] as String),
  action: j['action'] as String,
  overrideScheduledDate: _dt(j['overrideScheduledDate']),
);

PomodoroRecord _pomodoroFromJson(Map<String, dynamic> j) => PomodoroRecord(
  id: j['id'] as int,
  taskId: j['taskId'] as int?,
  durationMinutes: j['durationMinutes'] as int,
  startedAt: DateTime.parse(j['startedAt'] as String),
  completedAt: DateTime.parse(j['completedAt'] as String),
);

/// 共享恢复事务：按原 ID 重建整棵树（任务+子树+提醒+完成记录+例外+番茄），
/// 全部在一个事务内，中途失败自动回滚。
/// 清单已被删除时兜底重映射到默认清单（防止外键失败导致任务永久丢失）。
/// 恢复成功后对整棵树重排提醒。
/// 调用方负责在成功后删除对应回收站条目并 bump dataVersion。
Future<void> restoreTrashSnapshot(
  AppDatabase db,
  ReminderScheduler scheduler,
  TrashSnapshot snap,
) async {
  await db.transaction(() async {
    var listId = snap.task.listId;
    if (await db.getListById(listId) == null) {
      await db.ensureDefaultList();
      listId = (await db.getDefaultList()).id;
    }
    await db.restoreTask(snap.task.copyWith(listId: listId));
    for (final s in snap.subTasks) {
      var sListId = s.listId;
      if (await db.getListById(sListId) == null) {
        sListId = listId;
      }
      await db.restoreTask(sListId == s.listId ? s : s.copyWith(listId: sListId));
    }
    for (final r in snap.reminders) {
      await db.insertReminderRaw(
        RemindersCompanion(
          id: Value(r.id),
          taskId: Value(r.taskId),
          remindMinutesBefore: Value(r.remindMinutesBefore),
          isPersistent: Value(r.isPersistent),
          remindAtMinutes: r.remindAtMinutes == null
              ? const Value(null)
              : Value(r.remindAtMinutes),
        ),
      );
    }
    for (final c in snap.completions) {
      await db.insertCompletionRaw(
        TaskCompletionsCompanion(
          id: Value(c.id),
          taskId: Value(c.taskId),
          instanceDate: Value(c.instanceDate),
          completedAt: Value(c.completedAt),
        ),
      );
    }
    for (final e in snap.exceptions) {
      await db.insertExceptionRaw(
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
      await db.insertPomodoroRaw(
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
  for (final tid in [snap.task.id, ...snap.subTasks.map((s) => s.id)]) {
    final restored = await db.getTask(tid);
    if (restored != null) {
      await scheduler.scheduleTask(restored);
    }
  }
}
