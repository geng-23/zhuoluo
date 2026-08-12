import 'package:zhuoluo/data/database/database.dart';

/// 任务域实体统一 JSON 编码（备份导出与回收站快照共用）。
/// schema 变化（tasks/reminders 等表加列）时只需在此处补字段，
/// 备份与回收站序列化同步生效，避免双份实现漂移。
String? dateToJson(DateTime? d) => d?.toIso8601String();

Map<String, dynamic> taskToJson(Task e) => {
  'id': e.id,
  'listId': e.listId,
  'parentId': e.parentId,
  'title': e.title,
  'note': e.note,
  'quadrant': e.quadrant,
  'planStart': dateToJson(e.planStart),
  'planEnd': dateToJson(e.planEnd),
  'dueTime': dateToJson(e.dueTime),
  'isAllDay': e.isAllDay,
  'color': e.color,
  'rrule': e.rrule,
  'hasReminder': e.hasReminder,
  'hasNote': e.hasNote,
  'sortOrder': e.sortOrder,
  'skippedDates': e.skippedDates,
  'completedAt': dateToJson(e.completedAt),
  'createdAt': e.createdAt.toIso8601String(),
};

Map<String, dynamic> reminderToJson(Reminder e) => {
  'id': e.id,
  'taskId': e.taskId,
  'remindMinutesBefore': e.remindMinutesBefore,
  'isPersistent': e.isPersistent,
  'remindAtMinutes': e.remindAtMinutes,
};

Map<String, dynamic> completionToJson(TaskCompletion e) => {
  'id': e.id,
  'taskId': e.taskId,
  'instanceDate': e.instanceDate.toIso8601String(),
  'completedAt': e.completedAt.toIso8601String(),
};

Map<String, dynamic> exceptionToJson(TaskException e) => {
  'id': e.id,
  'taskId': e.taskId,
  'instanceDate': e.instanceDate.toIso8601String(),
  'action': e.action,
  'overrideScheduledDate': dateToJson(e.overrideScheduledDate),
};

Map<String, dynamic> pomodoroToJson(PomodoroRecord e) => {
  'id': e.id,
  'taskId': e.taskId,
  'durationMinutes': e.durationMinutes,
  'startedAt': e.startedAt.toIso8601String(),
  'completedAt': e.completedAt.toIso8601String(),
};
