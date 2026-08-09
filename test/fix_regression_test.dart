import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/task/providers.dart';

import 'support/fake_notification_scheduler.dart';

/// 2026-08-08 21:27 总览新发现 3 项 + 第二批 3 项（P1-27 纯 UI 钳制，
/// 与既有 7 处同模式，analyze 覆盖）回归测试：
/// - 新发现①：日历侧跳过/撤销跳过与任务页统一（完成记录暂存恢复 + JSON 容错）
/// - 新发现③：applyRecurringChange 返回被清理的完成记录/例外（改期撤销恢复）
/// - 新发现②：习惯提醒走独立渠道（schedule 渠道参数路径不抛异常）
/// - P1-21：导入缺表键兜底
/// - P1-4：导入完成/打卡日期归一化（00:00 基准）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    String rrule = '',
    DateTime? planStart,
    bool isAllDay = false,
    int? parentId,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: title,
        planStart: Value(planStart),
        isAllDay: Value(isAllDay),
        rrule: Value(rrule),
        parentId: Value(parentId),
        createdAt: now,
      ),
    );
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('新发现① 日历侧跳过/撤销与任务页统一（P0-2 日历入口 + P2-40）', () {
    test('日历侧跳过→撤销：完成记录恢复且完成时间保留', () async {
      final start = today.subtract(const Duration(days: 5));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      final doneAt = DateTime(now.year, now.month, now.day, 8, 30);
      await db.completeInstance(id, today);
      await db.restoreInstanceCompletion(id, today, doneAt);

      final container = makeContainer();
      final calendar = container.read(calendarControllerProvider.notifier);
      await calendar.skipInstance(id, today);
      // _bump 触发的 dataVersion 监听 load() 是 fire-and-forget，需等待完成
      //（否则 tearDown 关闭 DB 后仍在执行抛 "Can't re-open"）
      await calendar.load();
      expect(
        await db.isInstanceCompleted(id, today),
        isFalse,
        reason: '跳过实例应清理当天完成记录',
      );

      await calendar.unskipInstance(id, today);
      await calendar.load();
      final comp = await db.getInstanceCompletion(id, today);
      expect(comp, isNotNull, reason: '撤销跳过后完成记录应恢复');
      expect(
        comp!.completedAt,
        doneAt,
        reason: '恢复的完成记录应保留原完成时间（统计不漂移）',
      );
    });

    test('日历侧跳过：非法 skippedDates JSON 不抛异常（P2-40 容错）', () async {
      final start = today.subtract(const Duration(days: 5));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      // 损坏备份导入产生的非法 JSON
      await db.updateTask(
        id,
        const TasksCompanion(skippedDates: Value('not json')),
      );
      final container = makeContainer();
      final calendar = container.read(calendarControllerProvider.notifier);
      await calendar.skipInstance(id, today);
      await calendar.load(); // 等待 dataVersion 触发的 fire-and-forget load 完成
      final t = await db.getTask(id);
      expect(t!.skippedDates, contains(today.toIso8601String()),
          reason: '非法 JSON 静默视为无跳过，本次跳过仍生效');
    });

    test('任务页跳过→撤销：行为与日历侧一致（完成时间保留）', () async {
      final start = today.subtract(const Duration(days: 5));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      final doneAt = DateTime(now.year, now.month, now.day, 9, 15);
      await db.completeInstance(id, today);
      await db.restoreInstanceCompletion(id, today, doneAt);

      final container = makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      await notifier.skipInstance(id, today);
      await notifier.unskipInstance(id, today);
      // 等待 dataVersion 触发的 fire-and-forget reload 完成（同 tearDown 竞态）
      await notifier.reload();
      final comp = await db.getInstanceCompletion(id, today);
      expect(comp, isNotNull);
      expect(comp!.completedAt, doneAt);
    });
  });

  group('新发现③ 改期撤销恢复被清理的完成记录/例外（P2-52）', () {
    test('applyRecurringChange 返回被清理的例外列表', () async {
      final start = today.subtract(const Duration(days: 10));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: start.add(const Duration(days: 1)), // 不再命中 → 清理
          action: const Value('edit'),
          overrideScheduledDate: Value(start.add(const Duration(days: 5))),
        ),
      );
      final result = await db.applyRecurringChange(
        id,
        oldRrule: 'FREQ=DAILY',
        newRrule: 'FREQ=DAILY;INTERVAL=2',
        newStart: start,
      );
      expect(
        result.removedExceptions,
        hasLength(1),
        reason: '不命中新规则的例外应被返回（供撤销恢复）',
      );
      expect(await db.getExceptions(id), isEmpty);
    });

    test('清除重复：返回全部完成记录与例外', () async {
      final start = today.subtract(const Duration(days: 3));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      await db.completeInstance(id, start);
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: start,
          action: const Value('delete'),
        ),
      );
      final result = await db.applyRecurringChange(
        id,
        oldRrule: 'FREQ=DAILY',
        newRrule: '',
      );
      expect(result.removedCompletions, hasLength(1));
      expect(result.removedExceptions, hasLength(1));
    });

    test('模拟任务页改期→撤销全流程：日期+完成记录+例外全部恢复', () async {
      final start = today.subtract(const Duration(days: 10));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
        isAllDay: true,
      );
      await db.completeInstance(id, start);
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: start.add(const Duration(days: 1)),
          action: const Value('edit'),
          overrideScheduledDate: Value(start.add(const Duration(days: 5))),
        ),
      );

      // 改期（平移锚点 +2 天）：旧锚点完成记录/例外被清理
      final newStart = start.add(const Duration(days: 2));
      final result = await db.applyRecurringChange(
        id,
        oldRrule: 'FREQ=DAILY',
        newRrule: 'FREQ=DAILY',
        newStart: newStart,
      );
      expect(result.removedCompletions, hasLength(1));
      expect(result.removedExceptions, hasLength(1));
      expect(await db.getInstanceCompletion(id, start), isNull);

      // 撤销：恢复原锚点 + 被清理的完成记录与例外（对应 task_page._undoReschedule）
      await db.updateTask(
        id,
        TasksCompanion(planStart: Value(start), isAllDay: Value(true)),
      );
      for (final c in result.removedCompletions) {
        await db.insertCompletionRaw(
          TaskCompletionsCompanion(
            id: Value(c.id),
            taskId: Value(c.taskId),
            instanceDate: Value(c.instanceDate),
            completedAt: Value(c.completedAt),
          ),
        );
      }
      for (final e in result.removedExceptions) {
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
      expect(await db.getInstanceCompletion(id, start), isNotNull,
          reason: '撤销后旧锚点完成记录应恢复');
      expect(await db.getExceptions(id), hasLength(1),
          reason: '撤销后被清理的例外应恢复');
    });
  });

  group('新发现② 习惯提醒独立渠道（P2-51）', () {
    test('scheduleHabitReminder 走习惯渠道 + 逐日排期 + 已打卡跳过', () async {
      // 注入记录型替身：断言真实调度结果（此前依赖平台插件不可用时的
      // 异常吞掉行为，属"假绿"——断言的是环境失败而非功能正确性）
      final fake = FakeNotificationScheduler();
      NotificationService.instance.debugOverrideScheduler = fake;
      addTearDown(() => NotificationService.instance.debugOverrideScheduler = null);

      final habitId = await db.insertHabit(
        '阅读',
        '⭐',
        DateTime(now.year, now.month, now.day, 9, 0),
      );
      final habit = (await db.getHabit(habitId))!;
      final scheduler = ReminderScheduler(db);
      // 今天已打卡 → 今天的提醒应被跳过，从明天开始排
      final todayKey = DateTime(now.year, now.month, now.day);
      await db.checkHabit(habitId, todayKey);

      final ok = await scheduler.scheduleHabitReminder(habit);
      expect(ok, isTrue, reason: 'P2-51：替身环境调度成功应返回 true');
      // 93 天窗口 − 今天（已打卡跳过）= 92 条，全部走习惯渠道
      expect(fake.scheduled.length, 92,
          reason: 'P2-51：93 天逐日排期，今天已打卡跳过');
      expect(
        fake.scheduled.every((s) => s.channel == 'habit_reminder_v3'),
        isTrue,
        reason: 'P2-51：习惯提醒走独立渠道',
      );
      expect(
        fake.scheduled.every((s) => s.payload == 'h$habitId'),
        isTrue,
        reason: 'P2-51：深链载荷定位习惯',
      );
      // 第一条 = 明天 09:00
      final first = fake.scheduled.first;
      expect(
        first.when.difference(
          DateTime(now.year, now.month, now.day + 1, 9, 0),
        ).inMinutes.abs(),
        lessThanOrEqualTo(1),
        reason: 'P2-51：明天 09:00 开始排期',
      );
    });
  });

  group('P1-21 导入缺表键兜底', () {
    test('缺 lists/tasks 以外表键的备份：parseBackupStats 非 null 且可导入', () async {
      final json = jsonEncode({
        'version': 1,
        'exportedAt': now.toIso8601String(),
        'lists': [
          {
            'id': 1,
            'name': '收件箱',
            'color': '#4F8EF7',
            'sortOrder': 0,
            'showInCalendar': true,
            'isDefault': true,
            'createdAt': now.toIso8601String(),
          },
        ],
        'tasks': [
          {
            'id': 1,
            'listId': 1,
            'parentId': null,
            'title': '任务A',
            'note': '',
            'quadrant': 4,
            'planStart': null,
            'planEnd': null,
            'dueTime': null,
            'isAllDay': false,
            'color': '',
            'rrule': '',
            'hasReminder': false,
            'hasNote': false,
            'sortOrder': 0,
            'skippedDates': '[]',
            'completedAt': null,
            'createdAt': now.toIso8601String(),
          },
        ],
      });
      final service = BackupService(db);
      final stats = service.parseBackupStats(json);
      expect(stats, isNotNull, reason: '缺表键不应返回 null');
      expect(stats!.tasks, 1);
      expect(stats.lists, 1);
      expect(stats.reminders, 0);

      final count = await service.importJson(json);
      expect(count, 1, reason: '缺表键备份应可导入');
    });

    test('表键为 null 的备份同样兜底（不抛 TypeError）', () async {
      final json = jsonEncode({
        'version': 1,
        'exportedAt': now.toIso8601String(),
        'lists': null,
        'tasks': [],
        'reminders': null,
        'completions': null,
        'exceptions': null,
        'habits': null,
        'habitRecords': null,
        'pomodoros': null,
        'settings': null,
      });
      final service = BackupService(db);
      final stats = service.parseBackupStats(json);
      expect(stats, isNotNull);
      final count = await service.importJson(json);
      expect(count, 0);
    });
  });

  group('P1-4 导入完成/打卡日期归一化', () {
    test('导入带时分的实例完成记录：恢复后"已完成"状态不丢', () async {
      final json = jsonEncode({
        'version': 1,
        'exportedAt': now.toIso8601String(),
        'lists': [
          {
            'id': 1,
            'name': '收件箱',
            'color': '#4F8EF7',
            'sortOrder': 0,
            'showInCalendar': true,
            'isDefault': true,
            'createdAt': now.toIso8601String(),
          },
        ],
        'tasks': [
          {
            'id': 1,
            'listId': 1,
            'parentId': null,
            'title': '每日',
            'note': '',
            'quadrant': 4,
            'planStart': DateTime(2026, 7, 1).toIso8601String(),
            'planEnd': DateTime(2026, 7, 1, 1).toIso8601String(),
            'dueTime': null,
            'isAllDay': false,
            'color': '',
            'rrule': 'FREQ=DAILY',
            'hasReminder': false,
            'hasNote': false,
            'sortOrder': 0,
            'skippedDates': '[]',
            'completedAt': null,
            'createdAt': now.toIso8601String(),
          },
        ],
        'reminders': <dynamic>[],
        'completions': [
          {
            'id': 1,
            'taskId': 1,
            // 带时分（旧版导出格式）：归一化后应与规则展开基准一致
            'instanceDate': '2026-07-15T09:30:00.000',
            'completedAt': '2026-07-15T09:45:00.000',
          },
        ],
        'exceptions': <dynamic>[],
        'habits': <dynamic>[],
        'habitRecords': <dynamic>[],
        'pomodoros': <dynamic>[],
        'settings': <dynamic>[],
      });
      await BackupService(db).importJson(json);
      expect(
        await db.isInstanceCompleted(1, DateTime(2026, 7, 15)),
        isTrue,
        reason: '导入后实例完成状态应保留（此前带时分与 00:00 基准互相不识别）',
      );
    });

    test('导入带时分的打卡记录：isHabitDone 为 true', () async {
      final json = jsonEncode({
        'version': 1,
        'exportedAt': now.toIso8601String(),
        'lists': <dynamic>[],
        'tasks': <dynamic>[],
        'reminders': <dynamic>[],
        'completions': <dynamic>[],
        'exceptions': <dynamic>[],
        'habits': [
          {
            'id': 1,
            'name': '阅读',
            'icon': '⭐',
            'frequency': 'daily',
            'reminderTime': null,
            'createdAt': now.toIso8601String(),
          },
        ],
        'habitRecords': [
          {
            'id': 1,
            'habitId': 1,
            'date': '2026-07-20T23:00:00.000', // 带时分
            'completedAt': '2026-07-20T23:05:00.000',
          },
        ],
        'pomodoros': <dynamic>[],
        'settings': <dynamic>[],
      });
      await BackupService(db).importJson(json);
      expect(
        await db.isHabitDone(1, DateTime(2026, 7, 20)),
        isTrue,
        reason: '导入后打卡状态应保留（此前带时分与 checkHabit 基准不匹配）',
      );
    });
  });

  group('P2-1 N+1 批量预取', () {
    test('批量预取方法：空 ids 防空返回空（不生成 IN () 非法 SQL）', () async {
      expect(await db.getExceptionsForTasks([]), isEmpty);
      expect(await db.getCompletedSetForTasks([], today, today), isEmpty);
    });

    test('清单全隐藏时 getCalendarItems 不崩（listIds 为空防空）', () async {
      final id = await insertTask(
        title: '任务A',
        planStart: today,
        isAllDay: true,
      );
      final list = await db.getListById((await db.getTask(id))!.listId);
      await db.updateList(list!.id, showInCalendar: false);
      final items = await db.getCalendarItems(today, today);
      expect(items, isEmpty, reason: '全部清单隐藏后日历应为空而非崩溃');
    });

    test('智能清单：窗口外完成记录不影响"今天"视图（预取范围正确）', () async {
      final start = today.subtract(const Duration(days: 30));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      // 30 天前的实例已完成（窗口外），今天的实例未完成
      await db.completeInstance(id, start);
      final todayList = await db.getTasksForDate(today);
      expect(
        todayList.any((t) => t.id == id),
        isTrue,
        reason: '窗口外完成记录不应让今天的任务消失',
      );
    });

    test('智能清单：窗口内完成记录让任务从"今天"消失', () async {
      final start = today.subtract(const Duration(days: 5));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      await db.completeInstance(id, today);
      final todayList = await db.getTasksForDate(today);
      expect(
        todayList.any((t) => t.id == id),
        isFalse,
        reason: '今天实例已完成 → 不出现在"今天"视图',
      );
    });

    test('统计计划数：预取后跳过/例外语义不变', () async {
      final start = today.subtract(const Duration(days: 10));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      // 跳过今天
      await db.updateTask(
        id,
        TasksCompanion(
          skippedDates: Value(
            jsonEncode([today.toIso8601String()]),
          ),
        ),
      );
      final planned = await db.getPlannedCountByDay(today, today);
      expect(planned[today], isNull,
          reason: '跳过今天的重复任务不计入今天的计划数');
      expect(planned.values.fold<int>(0, (a, b) => a + b), 0);
    });
  });
}
