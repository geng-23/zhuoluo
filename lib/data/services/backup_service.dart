import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_platform.dart';
import 'package:zhuoluo/data/services/backup_types.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';

/// 备份/恢复服务（JSON 格式，设计文档 §9）
/// 文件系统操作按平台实现：native=真实文件，web=浏览器下载导出。
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  /// 自动备份相关设置键（备份方案设计 3.2/3.3）
  static const keyLastAutoBackupAt = 'lastAutoBackupAt';
  static const keyAutoBackupFailed = 'autoBackupFailed';

  /// 自动备份保留份数（备份方案设计 决策 2）
  static const keepBackupCount = 10;

  /// 导出全部数据为 JSON 字符串
  Future<String> exportJson() async {
    final lists = await _db.getAllLists();
    final tasks = await _db.allTasksForBackup();
    final reminders = await _db.allRemindersForBackup();
    final completions = await _db.allCompletionsForBackup();
    final exceptions = await _db.allExceptionsForBackup();
    final habits = await _db.getHabits();
    final habitRecords = await _db.getAllHabitRecords();
    final pomodoros = await _db.getPomodoros();
    final settings = await _db.allSettingsForBackup();

    final data = {
      'version': 1,
      'exportedAt': AppClock.now().toIso8601String(),
      'lists': lists.map((e) => _listToJson(e)).toList(),
      'tasks': tasks.map((e) => _taskToJson(e)).toList(),
      'reminders': reminders.map((e) => _reminderToJson(e)).toList(),
      'completions': completions.map((e) => _completionToJson(e)).toList(),
      'exceptions': exceptions.map((e) => _exceptionToJson(e)).toList(),
      'habits': habits.map((e) => _habitToJson(e)).toList(),
      'habitRecords': habitRecords.map((e) => _habitRecordToJson(e)).toList(),
      'pomodoros': pomodoros.map((e) => _pomodoroToJson(e)).toList(),
      'settings': settings
          .map((e) => {'key': e.key, 'value': e.value})
          .toList(),
    };
    return jsonEncode(data);
  }

  /// 导出到文件（应用文档目录 / 浏览器下载），返回文件路径或下载文件名
  Future<String> exportToFile({bool toDownloads = false}) async {
    final json = await exportJson();
    return exportToFileImpl(json, toDownloads: toDownloads);
  }

  /// 列出可恢复的备份文件（native：下载目录 + 应用文档目录；web：空列表）
  Future<List<String>> listBackupFiles() => listBackupFilesImpl();

  /// 读取备份文件内容
  Future<String> readFile(String path) => readFileImpl(path);

  /// H2：#30 删除备份文件（支持多份/全部）
  Future<void> deleteBackupFiles(List<String> paths) =>
      deleteBackupFilesImpl(paths);

  /// H2：备份文件详情（路径 + 文件名 + 修改时间）
  Future<List<BackupFileInfo>> listBackupInfos() => listBackupInfosImpl();

  /// 方案 A：导出到用户选定位置（系统保存对话框，默认下载目录）。
  /// 返回保存位置路径；用户取消返回 null。
  Future<String?> exportToUserLocation() async {
    final json = await exportJson();
    return exportToUserLocationImpl(json);
  }

  /// 方案 A：从系统打开对话框选择备份 JSON，返回文件内容；取消返回 null。
  Future<String?> importFromUserFile() => pickBackupFileImpl();

  /// 解析备份 JSON 的内容统计（导入确认框/完成报告用）。
  /// 非法 JSON/非着落备份返回 null。
  BackupStats? parseBackupStats(String json) {
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      if (data['version'] != 1) return null;
      return BackupStats(
        // P1-21：缺表键（不完整旧备份）兜底计 0，不抛 TypeError
        lists: _rows(data, 'lists').length,
        tasks: _rows(data, 'tasks').length,
        reminders: _rows(data, 'reminders').length,
        completions: _rows(data, 'completions').length,
        exceptions: _rows(data, 'exceptions').length,
        habits: _rows(data, 'habits').length,
        pomodoros: _rows(data, 'pomodoros').length,
      );
    } catch (_) {
      return null;
    }
  }

  /// P1-21：备份表键缺失/为 null（不完整旧备份）时兜底为空表；
  /// 键存在但类型错误仍抛 TypeError（数据损坏应明确报错而非静默吞掉）
  static List _rows(Map<String, dynamic> data, String key) =>
      data.containsKey(key) && data[key] != null
          ? data[key] as List
          : const [];

  /// 每天首次打开自动备份（备份方案设计 3.2）：
  /// 1) Settings 读 lastAutoBackupAt；距现在 <24h → 直接返回
  /// 2) exportJson → 写应用文档目录（私有目录，规避 Android 11+ 作用域存储限制）
  /// 3) 清理：全量备份文件（下载 + 私有目录）按修改时间降序，删除第 11 份及更旧
  /// 4) 成功 → 写 lastAutoBackupAt；失败 → 写 autoBackupFailed（角标提示）
  Future<bool> autoBackup() async {
    if (!autoBackupSupportedImpl()) return false;
    final last = await _db.getSetting(keyLastAutoBackupAt);
    if (last != null && last.isNotEmpty) {
      final t = DateTime.tryParse(last);
      if (t != null && AppClock.now().difference(t).inHours < 24) return true;
    }
    try {
      final json = await exportJson();
      await exportToFileImpl(json, toDownloads: false);
      final infos = await listBackupInfos();
      if (infos.length > keepBackupCount) {
        await deleteBackupFiles(
          infos.skip(keepBackupCount).map((f) => f.path).toList(),
        );
      }
      await _db.setSetting(keyLastAutoBackupAt, AppClock.now().toIso8601String());
      await _db.setSetting(keyAutoBackupFailed, '');
      return true;
    } catch (e) {
      try {
        await _db.setSetting(
          keyAutoBackupFailed,
          jsonEncode({
            'time': AppClock.now().toIso8601String(),
            'error': '$e',
          }),
        );
      } catch (_) {}
      return false;
    }
  }

  /// 导入 JSON 字符串：
  /// [merge] = false → 全量替换（单事务清空+写入，P0-3.6 原子操作）
  /// [merge] = true  → 合并（备份方案设计 3.4，单事务原子，失败自动回滚）
  /// 返回任务数量。
  Future<int> importJson(String json, {bool merge = false}) async {
    final data = jsonDecode(json) as Map<String, dynamic>;
    if (data['version'] != 1) {
      throw FormatException('不支持的备份版本');
    }
    // P1-21：缺表键（不完整旧备份）兜底为空表，不抛 TypeError
    final lists = _rows(data, 'lists').map(_jsonToList).toList();
    final tasks = _rows(data, 'tasks').map(_jsonToTask).toList();
    final reminders = _rows(data, 'reminders')
        .map(_jsonToReminder)
        .toList();
    final completions = _rows(data, 'completions')
        .map(_jsonToCompletion)
        .toList();
    final exceptions = _rows(data, 'exceptions')
        .map(_jsonToException)
        .toList();
    final habits = _rows(data, 'habits').map(_jsonToHabit).toList();
    final habitRecords = _rows(data, 'habitRecords')
        .map(_jsonToHabitRecord)
        .toList();
    final pomodoros = _rows(data, 'pomodoros')
        .map(_jsonToPomodoro)
        .toList();
    final settings = _rows(data, 'settings')
        .map(
          (e) => SettingsCompanion.insert(
            key: (e as Map<String, dynamic>)['key'] as String,
            value: e['value'] as String,
          ),
        )
        .toList();
    if (merge) {
      await _mergeAll(
        listRows: lists,
        taskRows: tasks,
        reminderRows: reminders,
        completionRows: completions,
        exceptionRows: exceptions,
        habitRows: habits,
        habitRecordRows: habitRecords,
        pomodoroRows: pomodoros,
        settingRows: settings,
      );
    } else {
      await _db.replaceAll(
        listRows: lists,
        taskRows: tasks,
        reminderRows: reminders,
        completionRows: completions,
        exceptionRows: exceptions,
        habitRows: habits,
        habitRecordRows: habitRecords,
        pomodoroRows: pomodoros,
        settingRows: settings,
      );
    }
    await _db.ensureDefaultList();
    return tasks.length;
  }

  /// 合并导入（备份方案设计 3.4）：
  /// 全部在单事务内，任何失败自动回滚；外键全部重映射到新 ID。
  /// 去重键：Lists.name；Tasks(listId,title) 非子任务 / (parentId,title) 子任务；
  /// Reminders(taskId,remindMinutesBefore,remindAtMinutes)；
  /// Completions(taskId,instanceDate)；Exceptions(taskId,instanceDate,action)；
  /// Habits.name；HabitRecords(habitId,date)；Pomodoros 直接追加；Settings 覆盖。
  Future<void> _mergeAll({
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
    await _db.transaction(() async {
      // 1) 清单：同名跳过，新清单插入并建 oldId→newId 映射
      // P1-22：默认清单标记不能继承/复制——本地已有默认时强制 false
      //（否则合并后 getDefaultList 抛 StateError，事务已提交却报"导入失败"）；
      // 本地无默认（空库首次合并）时保留备份值并跟踪，最多产生 1 个默认，
      // 保证导入后的 ensureDefaultList 不重复创建同名收件箱
      final listIdMap = <int, int>{};
      var hasDefault = await _db.hasDefaultList();
      for (final l in listRows) {
        final existing = await _db.getListByName(l.name.value);
        if (existing != null) {
          listIdMap[l.id.value] = existing.id;
          continue;
        }
        final insertDefault = !hasDefault && l.isDefault.value;
        if (insertDefault) hasDefault = true;
        final newId = await _db.insertListFull(
          ListsCompanion(
            name: Value(l.name.value),
            color: Value(l.color.value),
            sortOrder: Value(l.sortOrder.value),
            showInCalendar: Value(l.showInCalendar.value),
            isDefault: Value(insertDefault),
            createdAt: Value(l.createdAt.value),
          ),
        );
        listIdMap[l.id.value] = newId;
      }

      // 2) 任务：先父后子（子任务父必须已映射），按标题去重
      final taskIdMap = <int, int>{};
      Future<void> insertOne(TasksCompanion t, int listId, int? parentId) async {
        final existing = parentId == null
            ? await _db.getTaskByListAndTitle(listId, t.title.value)
            : await _db.getTaskByParentAndTitle(parentId, t.title.value);
        if (existing != null) {
          taskIdMap[t.id.value] = existing.id;
          return;
        }
        final newId = await _db.insertTaskFull(
          TasksCompanion(
            listId: Value(listId),
            parentId: parentId == null ? const Value(null) : Value(parentId),
            title: Value(t.title.value),
            note: Value(t.note.value),
            quadrant: Value(t.quadrant.value),
            planStart: t.planStart,
            planEnd: t.planEnd,
            dueTime: t.dueTime,
            isAllDay: Value(t.isAllDay.value),
            rrule: Value(t.rrule.value),
            color: Value(t.color.value),
            hasReminder: Value(t.hasReminder.value),
            hasNote: Value(t.hasNote.value),
            sortOrder: Value(t.sortOrder.value),
            skippedDates: Value(t.skippedDates.value),
            completedAt: t.completedAt,
            createdAt: Value(t.createdAt.value),
          ),
        );
        taskIdMap[t.id.value] = newId;
      }

      for (final t in taskRows.where((t) => t.parentId.value == null)) {
        final listId = listIdMap[t.listId.value];
        if (listId == null) continue; // 备份清单缺失（不合法）→ 跳过
        await insertOne(t, listId, null);
      }
      var pending = taskRows.where((t) => t.parentId.value != null).toList();
      while (pending.isNotEmpty) {
        final next = <TasksCompanion>[];
        var progressed = false;
        for (final t in pending) {
          final newParent = taskIdMap[t.parentId.value];
          if (newParent == null) {
            next.add(t);
            continue;
          }
          progressed = true;
          final listId = listIdMap[t.listId.value];
          if (listId == null) continue;
          await insertOne(t, listId, newParent);
        }
        pending = next;
        if (!progressed) {
          // 父任务缺失（备份不完整）：按独立任务插入，避免死循环
          for (final t in pending) {
            final listId = listIdMap[t.listId.value];
            if (listId == null) continue;
            await insertOne(t, listId, null);
          }
          break;
        }
      }

      // 3) 提醒：taskId 重映射；同三元组跳过
      for (final r in reminderRows) {
        final newTaskId = taskIdMap[r.taskId.value];
        if (newTaskId == null) continue;
        final dup = await _db.getReminderByTriple(
          newTaskId,
          r.remindMinutesBefore.value,
          r.remindAtMinutes.value,
        );
        if (dup != null) continue;
        await _db.insertReminderFull(
          RemindersCompanion(
            taskId: Value(newTaskId),
            remindMinutesBefore: Value(r.remindMinutesBefore.value),
            isPersistent: Value(r.isPersistent.value),
            remindAtMinutes: r.remindAtMinutes,
          ),
        );
      }

      // 4) 完成记录：taskId 重映射；(taskId,instanceDate) 重复跳过
      for (final c in completionRows) {
        final newTaskId = taskIdMap[c.taskId.value];
        if (newTaskId == null) continue;
        final dup = await _db.getInstanceCompletion(
          newTaskId,
          c.instanceDate.value,
        );
        if (dup != null) continue;
        await _db.insertCompletionFull(
          TaskCompletionsCompanion(
            taskId: Value(newTaskId),
            instanceDate: c.instanceDate,
            completedAt: c.completedAt,
          ),
        );
      }

      // 5) 例外：taskId 重映射；(taskId,instanceDate,action) 重复跳过
      for (final e in exceptionRows) {
        final newTaskId = taskIdMap[e.taskId.value];
        if (newTaskId == null) continue;
        final dup = await _db.getExceptionByTaskDateAction(
          newTaskId,
          e.instanceDate.value,
          e.action.value,
        );
        if (dup != null) continue;
        await _db.insertExceptionFull(
          TaskExceptionsCompanion(
            taskId: Value(newTaskId),
            instanceDate: e.instanceDate,
            action: Value(e.action.value),
            overrideScheduledDate: e.overrideScheduledDate,
          ),
        );
      }

      // 6) 习惯：同名跳过，新习惯插入并建 oldId→newId 映射
      final habitIdMap = <int, int>{};
      for (final h in habitRows) {
        final existing = await _db.getHabitByName(h.name.value);
        if (existing != null) {
          habitIdMap[h.id.value] = existing.id;
          continue;
        }
        final newId = await _db.insertHabitFull(
          HabitsCompanion(
            name: Value(h.name.value),
            icon: Value(h.icon.value),
            frequency: Value(h.frequency.value),
            reminderTime: h.reminderTime,
            createdAt: Value(h.createdAt.value),
          ),
        );
        habitIdMap[h.id.value] = newId;
      }

      // 7) 习惯打卡：(habitId,date) 重复跳过
      for (final r in habitRecordRows) {
        final newHabitId = habitIdMap[r.habitId.value];
        if (newHabitId == null) continue;
        final dup = await _db.getHabitRecordByDate(newHabitId, r.date.value);
        if (dup != null) continue;
        await _db.insertHabitRecordFull(
          HabitRecordsCompanion(
            habitId: Value(newHabitId),
            date: r.date,
            completedAt: r.completedAt,
          ),
        );
      }

      // 8) 番茄记录：taskId 重映射（可空），直接追加
      for (final p in pomodoroRows) {
        final oldTaskId = p.taskId.value;
        if (oldTaskId != null && taskIdMap[oldTaskId] == null) continue;
        await _db.insertPomodoroFull(
          PomodoroRecordsCompanion(
            taskId: oldTaskId == null
                ? const Value(null)
                : Value(taskIdMap[oldTaskId]),
            durationMinutes: Value(p.durationMinutes.value),
            startedAt: p.startedAt,
            completedAt: p.completedAt,
          ),
        );
      }

      // 9) 设置：备份值覆盖现有
      for (final s in settingRows) {
        await _db.setSetting(s.key.value, s.value.value);
      }
    });
  }

  // ---- 序列化 ----
  String? _dateToJson(DateTime? d) => d?.toIso8601String();

  Map<String, dynamic> _listToJson(TaskList e) => {
    'id': e.id,
    'name': e.name,
    'color': e.color,
    'sortOrder': e.sortOrder,
    'showInCalendar': e.showInCalendar,
    'isDefault': e.isDefault,
    'createdAt': e.createdAt.toIso8601String(),
  };

  Map<String, dynamic> _taskToJson(Task e) => {
    'id': e.id,
    'listId': e.listId,
    'parentId': e.parentId,
    'title': e.title,
    'note': e.note,
    'quadrant': e.quadrant,
    'planStart': _dateToJson(e.planStart),
    'planEnd': _dateToJson(e.planEnd),
    'dueTime': _dateToJson(e.dueTime),
    'isAllDay': e.isAllDay,
    'color': e.color,
    'rrule': e.rrule,
    'hasReminder': e.hasReminder,
    'hasNote': e.hasNote,
    'sortOrder': e.sortOrder,
    'skippedDates': e.skippedDates,
    'completedAt': _dateToJson(e.completedAt),
    'createdAt': e.createdAt.toIso8601String(),
  };

  Map<String, dynamic> _reminderToJson(Reminder e) => {
    'id': e.id,
    'taskId': e.taskId,
    'remindMinutesBefore': e.remindMinutesBefore,
    'isPersistent': e.isPersistent,
    'remindAtMinutes': e.remindAtMinutes,
  };

  Map<String, dynamic> _completionToJson(TaskCompletion e) => {
    'id': e.id,
    'taskId': e.taskId,
    'instanceDate': e.instanceDate.toIso8601String(),
    'completedAt': e.completedAt.toIso8601String(),
  };

  Map<String, dynamic> _exceptionToJson(TaskException e) => {
    'id': e.id,
    'taskId': e.taskId,
    'instanceDate': e.instanceDate.toIso8601String(),
    'action': e.action,
    'overrideScheduledDate': _dateToJson(e.overrideScheduledDate),
  };

  Map<String, dynamic> _habitToJson(Habit e) => {
    'id': e.id,
    'name': e.name,
    'icon': e.icon,
    'frequency': e.frequency,
    'reminderTime': _dateToJson(e.reminderTime),
    'createdAt': e.createdAt.toIso8601String(),
  };

  Map<String, dynamic> _habitRecordToJson(HabitRecord e) => {
    'id': e.id,
    'habitId': e.habitId,
    'date': e.date.toIso8601String(),
    'completedAt': e.completedAt.toIso8601String(),
  };

  Map<String, dynamic> _pomodoroToJson(PomodoroRecord e) => {
    'id': e.id,
    'taskId': e.taskId,
    'durationMinutes': e.durationMinutes,
    'startedAt': e.startedAt.toIso8601String(),
    'completedAt': e.completedAt.toIso8601String(),
  };

  // ---- 反序列化 ----
  DateTime? _jsonToDate(dynamic d) =>
      d == null ? null : DateTime.parse(d as String);

  ListsCompanion _jsonToList(dynamic j) => ListsCompanion(
    id: Value(j['id'] as int),
    name: Value(j['name'] as String),
    color: Value(j['color'] as String),
    sortOrder: Value(j['sortOrder'] as int),
    showInCalendar: Value(j['showInCalendar'] as bool),
    isDefault: Value(j['isDefault'] as bool),
    createdAt: Value(DateTime.parse(j['createdAt'] as String)),
  );

  TasksCompanion _jsonToTask(dynamic j) {
    // 兼容 v1 备份：scheduledDate/startTime/durationMinutes/dueDate → planStart/planEnd/dueTime
    DateTime? planStart;
    DateTime? planEnd;
    DateTime? dueTime;
    if (j.containsKey('planStart')) {
      planStart = _jsonToDate(j['planStart']);
      planEnd = _jsonToDate(j['planEnd']);
      dueTime = _jsonToDate(j['dueTime']);
    } else {
      final sd = _jsonToDate(j['scheduledDate']);
      final st = _jsonToDate(j['startTime']);
      final dur = (j['durationMinutes'] as int?) ?? 60;
      if (sd != null) {
        planStart = DateTime(
          sd.year,
          sd.month,
          sd.day,
          st?.hour ?? 0,
          st?.minute ?? 0,
        );
        planEnd = planStart.add(Duration(minutes: dur));
      }
      dueTime = _jsonToDate(j['dueDate']);
    }
    return TasksCompanion(
      id: Value(j['id'] as int),
      listId: Value(j['listId'] as int),
      parentId: j['parentId'] == null
          ? const Value(null)
          : Value(j['parentId'] as int),
      title: Value(j['title'] as String),
      note: Value(j['note'] as String),
      quadrant: Value(j['quadrant'] as int),
      planStart: planStart == null ? const Value(null) : Value(planStart),
      planEnd: planEnd == null ? const Value(null) : Value(planEnd),
      dueTime: dueTime == null ? const Value(null) : Value(dueTime),
      isAllDay: Value(j['isAllDay'] as bool),
      color: Value(j['color'] as String? ?? ''),
      rrule: Value(j['rrule'] as String),
      hasReminder: Value(j['hasReminder'] as bool),
      hasNote: Value(j['hasNote'] as bool),
      sortOrder: Value(j['sortOrder'] as int),
      skippedDates: Value(j['skippedDates'] as String),
      completedAt: _jsonToDate(j['completedAt']) == null
          ? const Value(null)
          : Value(_jsonToDate(j['completedAt'])),
      createdAt: Value(DateTime.parse(j['createdAt'] as String)),
    );
  }

  RemindersCompanion _jsonToReminder(dynamic j) => RemindersCompanion(
    id: Value(j['id'] as int),
    taskId: Value(j['taskId'] as int),
    remindMinutesBefore: Value(j['remindMinutesBefore'] as int),
    isPersistent: Value(j['isPersistent'] as bool),
    // 旧备份无该字段 → null（默认 09:00）
    remindAtMinutes: j['remindAtMinutes'] == null
        ? const Value(null)
        : Value(j['remindAtMinutes'] as int),
  );

  TaskCompletionsCompanion _jsonToCompletion(dynamic j) =>
      TaskCompletionsCompanion(
        id: Value(j['id'] as int),
        taskId: Value(j['taskId'] as int),
        // P1-4：实例日期归一化到当天 00:00（与 DB 基准一致，database.dart
        // completeInstance；否则恢复后"已完成"状态与规则展开互相不识别）
        instanceDate: Value(
          DateUtilsEx.normalizeInstanceDate(
            DateTime.parse(j['instanceDate'] as String),
          ),
        ),
        completedAt: Value(DateTime.parse(j['completedAt'] as String)),
      );

  TaskExceptionsCompanion _jsonToException(dynamic j) =>
      TaskExceptionsCompanion(
        id: Value(j['id'] as int),
        taskId: Value(j['taskId'] as int),
        instanceDate: Value(DateTime.parse(j['instanceDate'] as String)),
        action: Value(j['action'] as String),
        overrideScheduledDate: _jsonToDate(j['overrideScheduledDate']) == null
            ? const Value(null)
            : Value(_jsonToDate(j['overrideScheduledDate'])),
      );

  HabitsCompanion _jsonToHabit(dynamic j) => HabitsCompanion(
    id: Value(j['id'] as int),
    name: Value(j['name'] as String),
    icon: Value(j['icon'] as String),
    frequency: Value(j['frequency'] as String),
    reminderTime: _jsonToDate(j['reminderTime']) == null
        ? const Value(null)
        : Value(_jsonToDate(j['reminderTime'])),
    createdAt: Value(DateTime.parse(j['createdAt'] as String)),
  );

  HabitRecordsCompanion _jsonToHabitRecord(dynamic j) => HabitRecordsCompanion(
    id: Value(j['id'] as int),
    habitId: Value(j['habitId'] as int),
    // P1-4：打卡日期归一化到当天 00:00（与 isHabitDone/checkHabit 基准一致）
    date: Value(
      DateUtilsEx.normalizeInstanceDate(
        DateTime.parse(j['date'] as String),
      ),
    ),
    completedAt: Value(DateTime.parse(j['completedAt'] as String)),
  );

  PomodoroRecordsCompanion _jsonToPomodoro(dynamic j) =>
      PomodoroRecordsCompanion(
        id: Value(j['id'] as int),
        taskId: j['taskId'] == null
            ? const Value(null)
            : Value(j['taskId'] as int),
        durationMinutes: Value(j['durationMinutes'] as int),
        startedAt: Value(DateTime.parse(j['startedAt'] as String)),
        completedAt: Value(DateTime.parse(j['completedAt'] as String)),
      );
}
