import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/shell/home_shell.dart';

import '../support/fake_notification_scheduler.dart';

/// 通知深链：点击通知 payload → 跳任务详情 / 习惯页
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    // 任务/习惯操作触发提醒调度，注入替身
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<void> pumpShell(WidgetTester tester) async {
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
  }

  testWidgets('t{id} payload：跳转任务详情页', (tester) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '深链任务',
      createdAt: DateTime.now(),
    ));
    await pumpShell(tester);

    // 向通知点击流发送 payload
    NotificationService.instance.debugSimulateTap('t$id');
    await tester.pumpAndSettle();

    // 应导航到任务详情页
    expect(find.text('任务详情'), findsOneWidget,
        reason: '深链应打开任务详情页');
    expect(find.text('深链任务'), findsWidgets,
        reason: '详情页显示任务标题');
  });

  testWidgets('h{id} payload：跳转习惯页并定位习惯', (tester) async {
    await db.ensureDefaultList();
    final habitId = await db.insertHabit('深链习惯', '⭐', null);
    await pumpShell(tester);

    NotificationService.instance.debugSimulateTap('h$habitId');
    await tester.pumpAndSettle();

    // 应导航到习惯页并显示该习惯
    expect(find.text('深链习惯'), findsWidgets,
        reason: '深链应打开习惯页并显示目标习惯');
  });

  testWidgets('非法 payload 不导航（容错）', (tester) async {
    await pumpShell(tester);
    NotificationService.instance.debugSimulateTap('xyz');
    await tester.pumpAndSettle();
    // 仍停留在主壳（无详情页）
    expect(find.text('任务详情'), findsNothing, reason: '非法 payload 不导航');
    expect(find.text('任务'), findsWidgets, reason: '仍在主壳');
  });
}
