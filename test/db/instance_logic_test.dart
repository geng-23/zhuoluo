import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

/// 实例完成/全天提醒时刻回归测试
void main() {
  // 固定时钟：套件内所有"今天"口径一致，跨午夜不漂移
  AppClock.setNow(DateTime(2026, 8, 20, 10, 0));
  final now = AppClock.now();
  final today = DateTime(now.year, now.month, now.day);
  tearDownAll(() => AppClock.setNow(null));

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    String rrule = '',
    DateTime? planStart,
    bool isAllDay = false,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      planStart: Value(planStart),
      isAllDay: Value(isAllDay),
      rrule: Value(rrule),
      createdAt: now,
    ));
  }

  test('全天任务提醒：按提醒时刻计算（09:00 提前 30 分钟 = 08:30）', () async {
    final id = await insertTask(
      title: '全天任务',
      isAllDay: true,
      planStart: today,
    );
    final task = (await db.getTask(id))!;
    final reminderId = await db.insertReminder(RemindersCompanion.insert(
      taskId: id,
      remindMinutesBefore: const Value(30),
      remindAtMinutes: const Value(540), // 09:00
    ));
    final reminders = await db.getReminders(id);
    final times = ReminderScheduler(db).computeReminderTimes(
      task,
      today,
      reminders,
    );
    expect(times.single, DateTime(today.year, today.month, today.day, 8, 30),
        reason: '全天任务提醒 = 提醒时刻 09:00 减提前 30 分钟');
    expect(reminders.single.remindAtMinutes, 540);
    expect(reminderId, greaterThan(0));
  });

  test('reminderTriggerAt：全天任务按提醒时刻（21:00 准时 = 当天 21:00）', () {
    final task = Task(
      id: 1,
      listId: 1,
      parentId: null,
      title: '全天',
      note: '',
      quadrant: 4,
      planStart: today,
      planEnd: today.add(const Duration(days: 1)),
      dueTime: null,
      isAllDay: true,
      rrule: '',
      color: '',
      hasReminder: false,
      hasNote: false,
      sortOrder: 0,
      skippedDates: '[]',
      completedAt: null,
      createdAt: now,
    );
    // 21:00 准时提醒 → 当天 21:00（早于 21:00 时设置不应报"已过"）
    expect(
      reminderTriggerAt(task, 0, remindAtMinutes: 1260),
      DateTime(today.year, today.month, today.day, 21, 0),
    );
    // 默认 09:00
    expect(
      reminderTriggerAt(task, 0),
      DateTime(today.year, today.month, today.day, 9, 0),
    );
    // 21:00 提前 30 分钟
    expect(
      reminderTriggerAt(task, 30, remindAtMinutes: 1260),
      DateTime(today.year, today.month, today.day, 20, 30),
    );
  });

  test('reminderTriggerAt：定时任务按 planStart 时分，重复任务按今天', () {
    final timed = Task(
      id: 2,
      listId: 1,
      parentId: null,
      title: '定时',
      note: '',
      quadrant: 4,
      planStart: DateTime(today.year, today.month, today.day, 14, 30),
      planEnd: DateTime(today.year, today.month, today.day, 15, 30),
      dueTime: null,
      isAllDay: false,
      rrule: '',
      color: '',
      hasReminder: false,
      hasNote: false,
      sortOrder: 0,
      skippedDates: '[]',
      completedAt: null,
      createdAt: now,
    );
    expect(
      reminderTriggerAt(timed, 30),
      DateTime(today.year, today.month, today.day, 14, 0),
    );

    // 重复任务：planStart 在 7 天前，也应按今天计算实例
    final recurring = Task(
      id: 3,
      listId: 1,
      parentId: null,
      title: '重复',
      note: '',
      quadrant: 4,
      planStart: today.subtract(const Duration(days: 7)),
      planEnd: null,
      dueTime: null,
      isAllDay: true,
      rrule: 'FREQ=DAILY',
      color: '',
      hasReminder: false,
      hasNote: false,
      sortOrder: 0,
      skippedDates: '[]',
      completedAt: null,
      createdAt: now,
    );
    expect(
      reminderTriggerAt(recurring, 0, remindAtMinutes: 1260),
      DateTime(today.year, today.month, today.day, 21, 0),
    );
  });

  test('全天任务提醒：remindAtMinutes 为空默认 09:00', () async {
    final id = await insertTask(
      title: '全天默认',
      isAllDay: true,
      planStart: today,
    );
    final task = (await db.getTask(id))!;
    await db.insertReminder(
      RemindersCompanion.insert(taskId: id, remindMinutesBefore: const Value(0)),
    );
    final times = ReminderScheduler(db).computeReminderTimes(
      task,
      today,
      await db.getReminders(id),
    );
    expect(times.single, DateTime(today.year, today.month, today.day, 9, 0),
        reason: '默认 09:00 准时提醒');
  });

  test('定时任务提醒：忽略 remindAtMinutes，按 planStart 提前', () async {
    final start = DateTime(today.year, today.month, today.day, 14, 30);
    final id = await insertTask(title: '定时任务', planStart: start);
    final task = (await db.getTask(id))!;
    await db.insertReminder(RemindersCompanion.insert(
      taskId: id,
      remindMinutesBefore: const Value(30),
      remindAtMinutes: const Value(540),
    ));
    final times = ReminderScheduler(db).computeReminderTimes(
      task,
      today,
      await db.getReminders(id),
    );
    expect(times.single, DateTime(today.year, today.month, today.day, 14, 0),
        reason: '定时任务按 planStart 14:30 减 30 分钟');
  });

  test('备份 JSON 往返保留 remindAtMinutes（旧备份缺省为 null）', () async {
    final id = await insertTask(title: '备份任务', isAllDay: true, planStart: today);
    await db.insertReminder(RemindersCompanion.insert(
      taskId: id,
      remindMinutesBefore: const Value(10),
      remindAtMinutes: const Value(600), // 10:00
    ));
    final json = await BackupService(db).exportJson();
    expect(json, contains('"remindAtMinutes":600'));

    // 旧格式备份（无 remindAtMinutes，也无 checksum 字段）恢复后为 null
    final data = jsonDecode(json) as Map<String, dynamic>;
    final reminders = (data['reminders'] as List);
    (reminders.first as Map<String, dynamic>).remove('remindAtMinutes');
    data.remove('checksum');
    final legacy = jsonEncode(data);
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await db2.ensureDefaultList();
    await BackupService(db2).importJson(legacy);
    final restored = await db2.getReminders(id);
    expect(restored.single.remindAtMinutes, isNull);
  });

  test('schema v4：reminders 表包含 remind_at_minutes 列', () async {
    final cols = await db.customSelect(
      "SELECT name FROM pragma_table_info('reminders')",
    ).get();
    final names = cols.map((r) => r.read<String>('name')).toList();
    expect(names, contains('remind_at_minutes'));
    expect(names, contains('remind_minutes_before'));
  });

  test('重复任务实例完成切换：完成后可撤销，再完成可重复', () async {
    final id = await insertTask(
      title: '每日任务',
      rrule: 'FREQ=DAILY',
      planStart: today,
    );
    await db.completeInstance(id, today);
    expect(await db.isInstanceCompleted(id, today), isTrue);
    await db.uncompleteInstance(id, today);
    expect(await db.isInstanceCompleted(id, today), isFalse);
    await db.completeInstance(id, today);
    expect(await db.isInstanceCompleted(id, today), isTrue);
  });

  test('重复任务实例完成不影响其他实例', () async {
    final id = await insertTask(
      title: '每日任务2',
      rrule: 'FREQ=DAILY',
      planStart: today,
    );
    final tomorrow = today.add(const Duration(days: 1));
    await db.completeInstance(id, today);
    expect(await db.isInstanceCompleted(id, today), isTrue);
    expect(await db.isInstanceCompleted(id, tomorrow), isFalse);
  });

  test('父子联动：子任务全部完成后父任务自动完成，恢复一个子任务后父任务恢复未完成', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final parentId = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '父任务',
      createdAt: now,
    ));
    final c1 = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      parentId: Value(parentId),
      title: '子1',
      createdAt: now,
    ));
    final c2 = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      parentId: Value(parentId),
      title: '子2',
      createdAt: now,
    ));

    // 初始：父任务未完成
    expect((await db.getTask(parentId))!.completedAt, isNull);

    // 完成子1 → 父不联动（还有子2）
    await db.completeTask(c1);
    await db.maybeAutoCompleteParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNull);

    // 完成子2 → 父任务自动完成
    await db.completeTask(c2);
    await db.maybeAutoCompleteParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNotNull);

    // 恢复子1 → 父任务恢复未完成
    await db.reopenTask(c1);
    await db.maybeReopenParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNull,
        reason: '有子任务未完成时父任务应恢复未完成');

    // 父任务本来就未完成：调用 maybeReopenParent 无副作用
    await db.maybeReopenParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNull);
  });

  test('firstHitOnOrAfter：锚点吸附到规则第一个命中日', () {
    final r = RruleService.instance;
    // 周一锚点 + 周二周三 → 下一个周二
    // 2026-08-10 是周一
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 10), 'FREQ=WEEKLY;BYDAY=TU,WE'),
      DateTime(2026, 8, 11),
    );
    // 锚点本身命中（周二）→ 保持当天
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 11), 'FREQ=WEEKLY;BYDAY=TU,WE'),
      DateTime(2026, 8, 11),
    );
    // 每月 15 号：锚点 8/1 → 8/15
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 1), 'FREQ=MONTHLY;BYMONTHDAY=15'),
      DateTime(2026, 8, 15),
    );
    // 锚点 8/15 本身命中 → 保持
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 15), 'FREQ=MONTHLY;BYMONTHDAY=15'),
      DateTime(2026, 8, 15),
    );
    // 每月 15 号：锚点 8/20（已过）→ 9/15
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 20), 'FREQ=MONTHLY;BYMONTHDAY=15'),
      DateTime(2026, 9, 15),
    );
    // 每年：锚点（8/10）即规则月日 → 命中当天
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 10), 'FREQ=YEARLY'),
      DateTime(2026, 8, 10),
    );
    // 每天 → 锚点当天
    expect(
      r.firstHitOnOrAfter(DateTime(2026, 8, 10), 'FREQ=DAILY'),
      DateTime(2026, 8, 10),
    );
  });

  test('YEARLY 锚定 2/29：非闰年跳过，展开与命中判定同口径', () {
    final r = RruleService.instance;
    final hits = r.expand(
      DateTime(2024, 2, 29),
      'FREQ=YEARLY',
      to: DateTime(2031, 12, 31),
    );
    // 仅闰年产生实例（2024、2028；2032 超出窗口）
    expect(hits.map((d) => d.year).toSet(), {2024, 2028},
        reason: '非闰年必须整年跳过');
    for (final d in hits) {
      expect(d.month, 2, reason: '不得进位为 3/1 实例');
      expect(d.day, 29);
    }
    // 命中判定与展开一致：非闰年 3/1 永不命中
    expect(
      r.hitsOn('FREQ=YEARLY', DateTime(2024, 2, 29), DateTime(2025, 3, 1)),
      isFalse,
      reason: '修复前展开出现 2025-03-01 但 hitsOn 判不命中（口径分裂）',
    );
    expect(
      r.hitsOn('FREQ=YEARLY', DateTime(2024, 2, 29), DateTime(2028, 2, 29)),
      isTrue,
    );
    // MONTHLY 的无效日口径保持一致：锚定 31 号遇小月同样整月跳过
    final monthly = r.expand(
      DateTime(2026, 1, 31),
      'FREQ=MONTHLY',
      to: DateTime(2026, 12, 31),
    );
    expect(monthly.map((d) => d.month).toSet(), {1, 3, 5, 7, 8, 10, 12},
        reason: '小月（无 31 号）不得出现进位实例');
  });

  // ---------- 今日对齐父子联动 ----------

  Future<int> insertParentChild({
    required String parentTitle,
    String parentRrule = '',
    required List<(String, String)> children, // (title, rrule)
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final parentId = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: parentTitle,
      rrule: Value(parentRrule),
      planStart: Value(DateTime(today.year, today.month, today.day, 9)),
      createdAt: now,
    ));
    for (final (title, rrule) in children) {
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        parentId: Value(parentId),
        title: title,
        rrule: Value(rrule),
        planStart: Value(DateTime(today.year, today.month, today.day, 9)),
        createdAt: now,
      ));
    }
    return parentId;
  }

  test('今日对齐：重复子任务今日实例完成 + 非重复子任务完成 → 非重复父任务完成', () async {
    final parentId = await insertParentChild(
      parentTitle: '父',
      children: [('重复子', 'FREQ=DAILY'), ('普通子', '')],
    );

    // 只完成重复子任务今日实例 → 父不完成（普通子未完成）
    await db.completeInstance(
      (await db.getSubTasks(parentId))[0].id,
      today,
    );
    await db.maybeAutoCompleteParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNull);

    // 完成普通子任务 → 父任务完成
    await db.completeTask((await db.getSubTasks(parentId))[1].id);
    await db.maybeAutoCompleteParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNotNull);

    // 恢复重复子任务今日实例 → 父任务恢复未完成
    await db.uncompleteInstance((await db.getSubTasks(parentId))[0].id, today);
    await db.maybeReopenParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNull,
        reason: '有子任务今天未完成 → 父任务恢复未完成');
  });

  test('今日对齐：双重复子任务今日实例完成 → 重复父任务今日实例完成；恢复其一 → 恢复', () async {
    final parentId = await insertParentChild(
      parentTitle: '重复父',
      parentRrule: 'FREQ=DAILY',
      children: [('子1', 'FREQ=DAILY'), ('子2', 'FREQ=DAILY')],
    );

    // 子1 完成 → 父不完成（子2 未完成）
    await db.completeInstance((await db.getSubTasks(parentId))[0].id, today);
    await db.maybeAutoCompleteParent(parentId);
    expect(await db.isInstanceCompleted(parentId, today), isFalse);

    // 子2 完成 → 父今日实例完成
    await db.completeInstance((await db.getSubTasks(parentId))[1].id, today);
    await db.maybeAutoCompleteParent(parentId);
    expect(await db.isInstanceCompleted(parentId, today), isTrue);

    // 恢复子1 → 父今日实例恢复
    await db.uncompleteInstance((await db.getSubTasks(parentId))[0].id, today);
    await db.maybeReopenParent(parentId);
    expect(await db.isInstanceCompleted(parentId, today), isFalse,
        reason: '有子任务今天未完成 → 父今日实例恢复');
  });

  test('今日对齐：非重复子任务完成 → 重复父任务今日实例完成', () async {
    final parentId = await insertParentChild(
      parentTitle: '重复父',
      parentRrule: 'FREQ=DAILY',
      children: [('普通子', '')],
    );
    await db.completeTask((await db.getSubTasks(parentId))[0].id);
    await db.maybeAutoCompleteParent(parentId);
    expect(await db.isInstanceCompleted(parentId, today), isTrue);

    // 恢复普通子 → 父今日实例恢复
    await db.reopenTask((await db.getSubTasks(parentId))[0].id);
    await db.maybeReopenParent(parentId);
    expect(await db.isInstanceCompleted(parentId, today), isFalse);
  });

  test('今日对齐：父任务本来就未完成时，maybeReopenParent 无副作用', () async {
    final parentId = await insertParentChild(
      parentTitle: '父',
      children: [('子', '')],
    );
    await db.maybeReopenParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, isNull);
    expect(await db.isInstanceCompleted(parentId, today), isFalse);
  });

  test('今日对齐：父任务今日已完成时，maybeAutoCompleteParent 幂等不重复写', () async {
    final parentId = await insertParentChild(
      parentTitle: '父',
      children: [('子', '')],
    );
    await db.completeTask((await db.getSubTasks(parentId))[0].id);
    await db.maybeAutoCompleteParent(parentId);
    final first = (await db.getTask(parentId))!.completedAt!;
    await db.maybeAutoCompleteParent(parentId);
    expect((await db.getTask(parentId))!.completedAt, first,
        reason: '已完成的父任务不重复写完成时间');
  });
}
