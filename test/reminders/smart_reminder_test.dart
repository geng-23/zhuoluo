import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/shell/home_shell.dart';

import '../support/fake_notification_scheduler.dart';

/// 智能提醒回归测试：
/// - 通知深链 payload 编解码（新格式 r/d + 旧格式降级）
/// - deferReminder（贪睡/延后）：同 ID 重排、已完成跳过、明天语义、actions 透传
/// - scheduleTask 通知带结构化 payload 与「再提醒/已完成」按钮
/// - HomeShell 分发：snooze/done 不导航、正文点击打开详情 + 延后弹层
void main() {
  late AppDatabase db;
  late FakeNotificationScheduler fake;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  /// 播种一个定时任务（14:00-15:00，1 条准时提醒），返回定位信息
  Future<({int taskId, int reminderId, DateTime day})> seedTimedTask({
    String rrule = '',
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final start = AppClock.at(2026, 8, 13, 14, 0);
    final taskId = await db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: '提醒任务',
        planStart: Value(start),
        planEnd: Value(start.add(const Duration(hours: 1))),
        rrule: Value(rrule),
        createdAt: start,
      ),
    );
    final reminderId = await db.insertReminder(
      RemindersCompanion.insert(taskId: taskId, remindMinutesBefore: Value(0)),
    );
    return (
      taskId: taskId,
      reminderId: reminderId,
      day: AppClock.at(start.year, start.month, start.day),
    );
  }

  group('通知深链 payload 编解码', () {
    test('新格式 roundtrip（t{id}|r{rid}|d{日}）', () {
      final day = AppClock.at(2026, 8, 13);
      final p = reminderPayload(5, 3, day);
      final info = parseReminderTap(p)!;
      expect(info.taskId, 5);
      expect(info.reminderId, 3);
      expect(info.instanceDay, day);
    });

    test('旧格式 t{id} 兼容降级（无贪睡/延后信息）', () {
      final info = parseReminderTap('t5')!;
      expect(info.taskId, 5);
      expect(info.reminderId, isNull);
      expect(info.instanceDay, isNull);
    });

    test('非法 / null payload 返回 null', () {
      expect(parseReminderTap('xyz'), isNull);
      expect(parseReminderTap('h3'), isNull);
      expect(parseReminderTap(null), isNull);
    });
  });

  group('deferReminder（贪睡 / 延后）', () {
    test('贪睡 10 分钟：同 ID 重排、结构化 payload、带 actions', () async {
      final s = await seedTimedTask();
      final scheduler = ReminderScheduler(db);
      final before = AppClock.now();
      final ok = await scheduler.deferReminder(
        taskId: s.taskId,
        reminderId: s.reminderId,
        instanceDay: s.day,
      );
      expect(ok, isTrue);
      final rec = fake.lastScheduled!;
      expect(rec.id, NotificationIds.forReminder(s.reminderId, s.day));
      expect(rec.when.difference(before).inMinutes, closeTo(10, 1));
      expect(rec.payload, reminderPayload(s.taskId, s.reminderId, s.day));
      expect(rec.actions?.map((a) => a.id).toList(), [
        NotificationService.snoozeAction,
        NotificationService.doneAction,
      ]);
    });

    test('延后到明天 = 原提醒时刻 + 1 天', () async {
      final s = await seedTimedTask();
      final scheduler = ReminderScheduler(db);
      final ok = await scheduler.deferReminder(
        taskId: s.taskId,
        reminderId: s.reminderId,
        instanceDay: s.day,
        tomorrow: true,
      );
      expect(ok, isTrue);
      final rec = fake.lastScheduled!;
      // 原提醒时刻 = 实例日 14:00（提前量 0）；明天 = +1 天
      final expectAt = s.day
          .add(const Duration(hours: 14))
          .add(const Duration(days: 1));
      expect(
        rec.when.difference(expectAt).abs(),
        lessThan(const Duration(minutes: 1)),
        reason: '明天 = 原提醒时刻 + 1 天',
      );
    });

    test('已完成任务不重排贪睡', () async {
      final s = await seedTimedTask();
      await db.completeTask(s.taskId);
      final scheduler = ReminderScheduler(db);
      final ok = await scheduler.deferReminder(
        taskId: s.taskId,
        reminderId: s.reminderId,
        instanceDay: s.day,
      );
      expect(ok, isTrue);
      expect(fake.scheduled, isEmpty, reason: '已完成任务不再提醒');
    });

    test('重复任务已完成实例不重排贪睡', () async {
      final s = await seedTimedTask(rrule: 'RRULE:FREQ=DAILY');
      await db.completeInstanceIfHit(s.taskId, s.day);
      final scheduler = ReminderScheduler(db);
      final ok = await scheduler.deferReminder(
        taskId: s.taskId,
        reminderId: s.reminderId,
        instanceDay: s.day,
      );
      expect(ok, isTrue);
      expect(fake.scheduled, isEmpty, reason: '已完成实例不再提醒');
    });

    test('任务不存在返回 false', () async {
      final scheduler = ReminderScheduler(db);
      final ok = await scheduler.deferReminder(
        taskId: 999,
        reminderId: 1,
        instanceDay: AppClock.at(2026, 8, 13),
      );
      expect(ok, isFalse);
      expect(fake.scheduled, isEmpty);
    });
  });

  group('scheduleTask 通知载荷', () {
    test('任务提醒通知带结构化 payload 与「再提醒/已完成」按钮', () async {
      final s = await seedTimedTask();
      final scheduler = ReminderScheduler(db);
      final task = await db.getTask(s.taskId);
      await scheduler.scheduleTask(task!);
      final rec = fake.lastScheduled!;
      expect(rec.payload, reminderPayload(s.taskId, s.reminderId, s.day));
      expect(rec.actions?.map((a) => a.id).toList(), [
        NotificationService.snoozeAction,
        NotificationService.doneAction,
      ]);
    });
  });

  group('HomeShell 通知分发', () {
    Future<ProviderContainer> pumpShell(WidgetTester tester) async {
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: HomeShell()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('snooze action：贪睡重排且不导航', (tester) async {
      final s = await seedTimedTask();
      await pumpShell(tester);
      NotificationService.instance.debugSimulateTap(
        reminderPayload(s.taskId, s.reminderId, s.day),
        actionId: NotificationService.snoozeAction,
      );
      await tester.pumpAndSettle();
      expect(find.text('任务详情'), findsNothing, reason: '贪睡不打开详情');
      final rec = fake.lastScheduled;
      expect(rec, isNotNull);
      expect(
        rec!.id,
        NotificationIds.forReminder(s.reminderId, s.day),
        reason: '贪睡应同 ID 重排',
      );
    });

    testWidgets('done action：完成任务且不导航', (tester) async {
      final s = await seedTimedTask();
      await pumpShell(tester);
      NotificationService.instance.debugSimulateTap(
        reminderPayload(s.taskId, s.reminderId, s.day),
        actionId: NotificationService.doneAction,
      );
      await tester.pumpAndSettle();
      final t = await db.getTask(s.taskId);
      expect(t!.completedAt, isNotNull, reason: '已完成 action 直接完成任务');
      expect(find.text('任务详情'), findsNothing, reason: '完成不打开详情');
    });

    testWidgets('正文点击：打开详情 + 延后弹层，选 10 分钟重排', (tester) async {
      final s = await seedTimedTask();
      await pumpShell(tester);
      NotificationService.instance.debugSimulateTap(
        reminderPayload(s.taskId, s.reminderId, s.day),
      );
      await tester.pumpAndSettle();
      expect(find.text('任务详情'), findsOneWidget, reason: '正文点击打开详情');
      expect(find.text('延后提醒'), findsOneWidget, reason: '详情页弹出延后选择');

      await tester.tap(find.text('10 分钟'));
      await tester.pumpAndSettle();
      final rec = fake.lastScheduled;
      expect(rec, isNotNull);
      expect(
        rec!.id,
        NotificationIds.forReminder(s.reminderId, s.day),
        reason: '延后选择触发同 ID 重排',
      );
      expect(find.text('已设置稍后提醒'), findsOneWidget);
    });

    testWidgets('旧格式 payload 正文点击：打开详情但无延后弹层', (tester) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final id = await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '旧格式任务',
          createdAt: AppClock.now(),
        ),
      );
      await pumpShell(tester);
      NotificationService.instance.debugSimulateTap('t$id');
      await tester.pumpAndSettle();
      expect(find.text('任务详情'), findsOneWidget);
      expect(find.text('延后提醒'), findsNothing, reason: '无 r/d 信息不弹延后选择');
    });
  });
}
