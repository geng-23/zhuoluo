import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/main.dart';

import '../support/fake_notification_scheduler.dart';

/// 日历交互：月视图长按快速添加 / 月格任务摘要
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await db.ensureDefaultList();
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZhuoluoApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> switchToMonthView(WidgetTester tester) async {
    // 切到日历 tab
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    // 打开侧边栏选月视图
    await tester.tap(find.byIcon(Icons.menu).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('月视图'));
    await tester.pumpAndSettle();
  }

  testWidgets('月视图长按日期弹出快速添加面板', (tester) async {
    await pumpApp(tester);
    await switchToMonthView(tester);

    // 月格存在（找 1 号格，长按）
    final dayCell = find.text('1').first;
    expect(dayCell, findsWidgets, reason: '月视图应有日期格');
    await tester.longPress(dayCell);
    await tester.pumpAndSettle();

    // 快速添加面板出现（含标题输入框与添加按钮）
    expect(find.text('添加'), findsWidgets, reason: '长按应弹出快速添加');
  });

  testWidgets('月格显示任务摘要（含 N 个更多徽标）', (tester) async {
    await pumpApp(tester);
    // 造 5 个同一天任务（今天），月视图当天格应有摘要
    final list = await db.getDefaultList();
    final now = DateTime.now();
    for (var i = 0; i < 5; i++) {
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '任务$i',
        planStart: Value(DateTime(now.year, now.month, now.day, 9)),
        planEnd: Value(DateTime(now.year, now.month, now.day, 10)),
        createdAt: now,
      ));
    }
    await switchToMonthView(tester);
    // 数据版本变化触发日历重载
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 当天格显示"更多"徽标（5 个任务 > 2 个展示上限 → +3）
    expect(find.text('+3'), findsOneWidget,
        reason: '月格超过 2 个任务应显示 +N 更多徽标');
  });
}
