import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/task_ext.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/features/profile/pomodoro_page.dart';
import 'package:zhuoluo/features/task/providers.dart';

import '../support/fake_notification_scheduler.dart';

/// 回归测试：统计口径 / 截止时间 / 清单与置顶 / 重复任务 / 解析边界 / 提醒调度 / 番茄
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
    DateTime? dueTime,
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
        dueTime: Value(dueTime),
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

  Future<void> settle(ProviderContainer container) async {
    final state = container.read(tasksControllerProvider);
    var guard = 0;
    while (state.loading && guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
  }

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  /// 等待控制器任务列表达到指定数量。重载链（任务+实例+今日完成多次异步查询）
  /// 在高负载下可能超过固定延时，读旧列表会误报排序失败——轮询而非盲等。
  Future<void> waitTaskCount(ProviderContainer container, int count) async {
    var guard = 0;
    while (
        container.read(tasksControllerProvider).tasks.length < count &&
            guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
  }

  group('统计口径', () {
    test('完成数只计顶层任务，子任务与重复子任务实例不计入', () async {
      final parentId = await insertTask(
        title: '父任务',
        planStart: today,
      );
      final subId = await insertTask(
        title: '子任务',
        parentId: parentId,
        planStart: today,
      );
      final recSubId = await insertTask(
        title: '重复子任务',
        parentId: parentId,
        rrule: 'FREQ=DAILY',
        planStart: today,
      );
      await db.completeTask(parentId);
      await db.completeTask(subId);
      await db.completeInstance(recSubId, today);

      final completed = await db.getCompletedCountByDay(today, today);
      final total = completed.values.fold(0, (a, b) => a + b);
      expect(total, 1,
          reason: '仅父任务计入完成数，子任务/重复子任务实例不计入');

      // 计划数同样只计顶层 → 口径一致（完成率不会超过 100%）
      final planned = await db.getPlannedCountByDay(today, today);
      final plannedTotal = planned.values.fold(0, (a, b) => a + b);
      expect(plannedTotal, 1,
          reason: '计划数只计顶层任务（父任务计划在今天）');
    });
  });

  group('仅截止时间任务', () {
    test('只有 dueTime 的任务在日历中按截止日展示', () async {
      final id = await insertTask(
        title: '仅截止',
        dueTime: DateTime(today.year, today.month, today.day, 18),
      );
      final items = await db.getCalendarItems(today, today);
      expect(items.map((i) => i.task.id), contains(id),
          reason: '仅截止时间任务不再从日历消失');
      expect(items.single.instanceDate, today);
    });

    test('逾期判断纳入 dueTime', () async {
      final t1 = Task(
        id: 1,
        listId: 1,
        parentId: null,
        title: '已过截止',
        note: '',
        quadrant: 4,
        planStart: null,
        planEnd: null,
        dueTime: today.subtract(const Duration(days: 1)),
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
      expect(t1.isOverdueNow, isTrue,
          reason: '截止时间已过应判定逾期');

      final t2 = Task(
        id: 2,
        listId: 1,
        parentId: null,
        title: '已完成',
        note: '',
        quadrant: 4,
        planStart: null,
        planEnd: null,
        dueTime: today.subtract(const Duration(days: 1)),
        isAllDay: false,
        rrule: '',
        color: '',
        hasReminder: false,
        hasNote: false,
        sortOrder: 0,
        skippedDates: '[]',
        completedAt: now,
        createdAt: now,
      );
      expect(t2.isOverdueNow, isFalse, reason: '已完成的截止任务不算逾期');
    });
  });

  group('currentListId 显式清除', () {
    test('从清单切回智能视图后 currentListId 真正清空', () async {
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      final listId = await notifier.createList('新清单', '#123456');
      await drain();

      notifier.selectList(listId);
      expect(container.read(tasksControllerProvider).currentListId, listId);

      notifier.selectSmartView('all');
      expect(container.read(tasksControllerProvider).currentListId, isNull,
          reason: '切到"全部"后旧清单 ID 必须清空（否则新任务会加进旧清单）');
      await drain();
    });

    test('删除当前清单后 currentListId 清空', () async {
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      final listId = await notifier.createList('待删清单', '#123456');
      await drain();
      notifier.selectList(listId);
      await notifier.deleteList(listId);
      expect(container.read(tasksControllerProvider).currentListId, isNull);
      await drain();
    });
  });

  group('任务按开始时间排序', () {
    test('按开始时间升序（最近在前），新任务按时间落位，无时间任务排最后', () async {
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      // 排序语义针对"全部"视图：无时间任务不在默认"未来 7 天"视图显示
      notifier.selectSmartView('all');
      await drain();
      // 先添加晚时间任务，再添加早时间任务：排序应无视添加顺序
      await notifier.addTask(
        title: '晚任务',
        planStart: AppClock.at(today.year, today.month, today.day, 18, 0),
      );
      await drain();
      await notifier.addTask(
        title: '早任务',
        planStart: AppClock.at(today.year, today.month, today.day, 9, 0),
      );
      await drain();
      // 无开始时间的任务排最后
      await notifier.addTask(title: '无时间任务');
      await drain();

      final state = container.read(tasksControllerProvider);
      final titles = state.tasks.map((t) => t.title).toList();
      expect(titles, ['早任务', '晚任务', '无时间任务'],
          reason: '任务列表按开始时间升序，无开始时间排最后');
    });

    test('相同开始时间按添加顺序稳定排序', () async {
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      // 切到"全部"视图：排序语义与"未来 7 天"默认视图过滤互不干扰
      notifier.selectSmartView('all');
      await drain();
      final a = await notifier.addTask(
        title: 'A',
        planStart: AppClock.at(today.year, today.month, today.day, 10, 0),
      );
      await drain();
      final b = await notifier.addTask(
        title: 'B',
        planStart: AppClock.at(today.year, today.month, today.day, 10, 0),
      );
      await drain();
      // 重载链高负载下可能未完成：轮询等两个任务都进列表再断言
      await waitTaskCount(container, 2);
      final state = container.read(tasksControllerProvider);
      final ids = state.tasks.map((t) => t.id).toList();
      expect(ids.indexOf(a), lessThan(ids.indexOf(b)),
          reason: '相同开始时间按添加顺序稳定排序');
    });
  });

  group('有限重复任务结束', () {
    test('COUNT 已耗尽的系列从"全部"排除', () async {
      final start = today.subtract(const Duration(days: 10));
      await insertTask(
        title: '已结束系列',
        rrule: 'FREQ=DAILY;COUNT=2',
        planStart: start,
      );
      final tasks = await db.getAllUncompleted();
      expect(tasks.map((t) => t.title), isNot(contains('已结束系列')),
          reason: 'COUNT 耗尽后不应出现在活动视图');
    });

    test('UNTIL 已过的系列从"全部"排除', () async {
      final start = today.subtract(const Duration(days: 30));
      final until = DateTime(today.year, today.month, today.day - 10);
      await insertTask(
        title: 'UNTIL 已过',
        rrule:
            'FREQ=DAILY;UNTIL=${until.year}${until.month.toString().padLeft(2, '0')}${until.day.toString().padLeft(2, '0')}',
        planStart: start,
      );
      final tasks = await db.getAllUncompleted();
      expect(tasks.map((t) => t.title), isNot(contains('UNTIL 已过')));
    });

    test('仍有未来实例的系列保留在"全部"', () async {
      await insertTask(
        title: '进行中系列',
        rrule: 'FREQ=DAILY;COUNT=5',
        planStart: today.subtract(const Duration(days: 2)),
      );
      final tasks = await db.getAllUncompleted();
      expect(tasks.map((t) => t.title), contains('进行中系列'),
          reason: 'COUNT=5 距今只过了 3 天，仍有未来实例');
    });

    test('系列结束后 nextInstance 不再回落到今天', () async {
      final container = makeContainer();
      await settle(container);
      final start = today.subtract(const Duration(days: 10));
      final id = await insertTask(
        title: '已结束系列2',
        rrule: 'FREQ=DAILY;COUNT=2',
        planStart: start,
      );
      await drain();
      final next = container.read(tasksControllerProvider).nextInstance[id];
      expect(next, isNull, reason: '无未来实例时 nextInstance 为 null');
    });
  });

  group('中文解析边界', () {
    final parser = ChineseDateParser.instance;
    final base = DateTime(2026, 8, 7); // 周五
    final todayBase = DateTime(2026, 8, 7);

    test('大后天解析为 +3 天（不被"后天"抢先）', () {
      final r = parser.parse('大后天交报告', now: base);
      expect(r.date, todayBase.add(const Duration(days: 3)));
      final r2 = parser.parse('后天交报告', now: base);
      expect(r2.date, todayBase.add(const Duration(days: 2)));
    });

    test('下午 3 点半 → 15:30', () {
      final r = parser.parse('下午3点半开会', now: base);
      expect(r.time!.hour, 15);
      expect(r.time!.minute, 30);
    });

    test('非法日期不解析（13 月 40 号不被 DateTime 自动进位）', () {
      final r = parser.parse('13月40号开会', now: base);
      expect(r.matched, isFalse);
      expect(r.date, isNull);
    });

    test('跨午夜：晚上 11 点到 1 点 → 23:00-01:00', () {
      final r = parser.parse('晚上11点到1点', now: base);
      expect(r.time!.hour, 23);
      expect(r.endTime!.hour, 1,
          reason: '结束时间应为次日凌晨 1 点（不得转成 13:00）');
    });

    test('明天每天阅读：日期与重复规则同时生效', () async {
      final r = parser.parse('明天每天阅读', now: base);
      expect(r.rrule, 'FREQ=DAILY');
      expect(r.date, todayBase.add(const Duration(days: 1)),
          reason: '重复任务起始日期应取解析出的"明天"');

      // 控制器侧：重复任务起始日期 + 全天语义
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      await notifier.addTaskFromParsed('明天每天阅读', r);
      await drain();
      final list = await db.getDefaultList();
      final tasks = await db.getTasksByList(list.id);
      final t = tasks.single;
      expect(t.planStart, todayBase.add(const Duration(days: 1)),
          reason: '起始日期为明天（此前会忽略日期落到今天）');
      expect(t.isAllDay, isTrue,
          reason: '无明确时间的重复任务应为全天（此前是 00:00-01:00 定时）');
      expect(t.rrule, 'FREQ=DAILY');
    });
  });

  group('提醒调度结果反馈', () {
    test('无提醒/已完成 → 视为成功；有提醒但排期失败 → 返回 false', () async {
      // 注入记录型替身：断言真实调度结果（此前依赖平台插件不可用的
      // 异常吞掉行为，属"假绿"——断言的是环境失败而非功能正确性）
      final fake = FakeNotificationScheduler();
      NotificationService.instance.debugOverrideScheduler = fake;
      addTearDown(() => NotificationService.instance.debugOverrideScheduler = null);

      final scheduler = ReminderScheduler(db);
      // 无提醒：true 且无调度调用
      final noReminder = await insertTask(title: '无提醒任务');
      final t1 = (await db.getTask(noReminder))!;
      expect(await scheduler.scheduleTask(t1), isTrue);
      expect(fake.scheduled, isEmpty,
          reason: '无提醒任务不应产生任何调度');

      // 有未来提醒：替身模拟排期失败 → false。
      // 计划时间用"现在 + 2 小时"而非"明天 00:00"：后者触发时刻为今天
      // 23:50，测试若在 23:50-23:59 运行会被调度器按"已过时刻"跳过而误挂
      final futureStart = AppClock.now().add(const Duration(hours: 2));
      final withReminder = await insertTask(
        title: '带提醒任务',
        planStart: futureStart,
      );
      await db.insertReminder(
        RemindersCompanion.insert(
          taskId: withReminder,
          remindMinutesBefore: const Value(10),
        ),
      );
      fake.failSchedules = true;
      final t2 = (await db.getTask(withReminder))!;
      expect(await scheduler.scheduleTask(t2), isFalse,
          reason: '排期失败应返回 false 供 UI 提示');

      // 替身恢复成功：应真实调度一条通知（ID 含实例维度 + 提前 10 分钟）
      fake.failSchedules = false;
      fake.clear();
      expect(await scheduler.scheduleTask(t2), isTrue);
      expect(fake.scheduled.length, 1,
          reason: '一条提醒应产生一条通知');
      final s = fake.scheduled.single;
      expect(s.title, '带提醒任务', reason: '通知标题 = 任务标题');
      // 提醒时刻 = 计划开始 − 10 分钟
      final expectedWhen = futureStart.add(const Duration(minutes: -10));
      expect(
        s.when.difference(expectedWhen).inMinutes.abs(),
        lessThanOrEqualTo(1),
        reason: '通知时刻 = 计划开始 − 提前 10 分钟',
      );
      expect(s.payload, 't$withReminder', reason: '深链载荷定位任务');
    });
  });

  group('番茄钟立即结束', () {
    testWidgets('立即结束记录 0 分钟（而非完整时长）', (tester) async {
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: PomodoroPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 开始后立即结束（不推进时间 → elapsed = 0）
      await tester.tap(find.text('开始'));
      await tester.pump();
      // 等按钮组 AnimatedSwitcher 过渡完成，新按钮才可命中
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('结束'));
      await tester.pumpAndSettle();

      final records = await db.getPomodoros();
      expect(records, hasLength(1));
      expect(records.single.durationMinutes, 0,
          reason: '立即结束应记录 0 分钟（此前会记录完整 15 分钟）');
    });
  });
}
