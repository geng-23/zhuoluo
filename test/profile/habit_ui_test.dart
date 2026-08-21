import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/habit_page.dart';

import '../support/fake_notification_scheduler.dart';

/// 习惯页：打卡/撤销交互与状态显示
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    Haptics.enabled = false;
    // 打卡后重排习惯提醒，注入替身避免平台异常
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  late int seedHabitId;

  Future<void> seedHabit({String name = '阅读', DateTime? reminderTime}) async {
    await db.ensureDefaultList();
    seedHabitId = await db.insertHabit(name, '⭐', reminderTime);
  }

  Future<void> pumpHabitPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HabitPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('打卡：点击后写入今日记录并显示已打卡', (tester) async {
    await seedHabit();
    await pumpHabitPage(tester);

    // 初始显示"今日未打卡"
    expect(find.text('今日未打卡'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    // 点击打卡
    await tester.tap(find.byIcon(Icons.radio_button_unchecked));
    await tester.pumpAndSettle();

    // 记录写入 + UI 更新
    expect(find.text('今日已打卡'), findsOneWidget,
        reason: '打卡后状态更新');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final today = DateTime.now();
    expect(
      await db.isHabitDone(
        seedHabitId,
        DateTime(today.year, today.month, today.day),
      ),
      isTrue,
      reason: '今日打卡记录写入',
    );
  });

  testWidgets('撤销打卡：撤销条点击后恢复未打卡', (tester) async {
    await seedHabit();
    // 跨测试去抖：showAppSnackBar 全局记录上一条消息（400ms 去抖窗口），
    // 前一个测试刚显示过相同文案会被吞掉——runAsync 真实等待越过去抖
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await pumpHabitPage(tester);

    // 打卡
    await tester.tap(find.byIcon(Icons.radio_button_unchecked));
    await tester.pumpAndSettle();
    expect(find.text('今日已打卡'), findsOneWidget);

    // 撤销条出现并点击撤销
    expect(find.text('已打卡「阅读」'), findsOneWidget, reason: '撤销条提示');
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    // 恢复未打卡
    expect(find.text('今日未打卡'), findsOneWidget, reason: '撤销后恢复');
    final today = DateTime.now();
    expect(
      await db.isHabitDone(
        seedHabitId,
        DateTime(today.year, today.month, today.day),
      ),
      isFalse,
      reason: '撤销后记录删除',
    );
  });

  testWidgets('今日已打卡的习惯进入页面即显示完成态', (tester) async {
    await seedHabit();
    final today = DateTime.now();
    await db.checkHabit(
      seedHabitId,
      DateTime(today.year, today.month, today.day),
    );
    await pumpHabitPage(tester);

    expect(find.text('今日已打卡'), findsOneWidget,
        reason: '已打卡习惯初始即完成态');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('新建习惯：默认图标为 ⭐，可点选其他图标落库', (tester) async {
    await db.ensureDefaultList();
    await pumpHabitPage(tester);

    // 打开新建弹窗，弹窗内应展示图标选择区
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('新建习惯'), findsOneWidget);
    expect(find.text('图标'), findsOneWidget);

    // 输入名称并点选图标 📚
    await tester.enterText(find.byType(TextField), '晨跑');
    await tester.tap(find.text('📚'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final habits = await db.getHabits();
    expect(habits, hasLength(1), reason: '创建成功');
    expect(habits.first.name, '晨跑');
    expect(habits.first.icon, '📚', reason: '点选的图标应落库');
  });

  testWidgets('新建习惯：不点图标时默认 ⭐', (tester) async {
    await db.ensureDefaultList();
    await pumpHabitPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '阅读');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final habits = await db.getHabits();
    expect(habits, hasLength(1));
    expect(habits.first.icon, '⭐', reason: '默认图标为 ⭐');
  });

  testWidgets('长按编辑图标：选择后落库并刷新列表', (tester) async {
    await seedHabit();
    await pumpHabitPage(tester);

    // 长按习惯行打开操作底栏
    await tester.longPress(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('编辑图标'), findsOneWidget);
    await tester.tap(find.text('编辑图标'));
    await tester.pumpAndSettle();

    // 选择 🏊 并确定
    await tester.tap(find.text('🏊'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final updated = await db.getHabit(seedHabitId);
    expect(updated!.icon, '🏊', reason: '编辑后的图标应落库');
  });
}
