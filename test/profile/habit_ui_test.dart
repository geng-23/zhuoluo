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

  testWidgets('点习惯行主体：打卡；再点取消打卡', (tester) async {
    await seedHabit();
    // 跨测试去抖：同撤销打卡用例，真实等待越过 400ms 同文案去抖窗口
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await pumpHabitPage(tester);
    expect(find.text('今日未打卡'), findsOneWidget);

    // 点行主体（名称）= 打卡
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('今日已打卡'), findsOneWidget, reason: '行主体点击触发打卡');
    final today = DateTime.now();
    expect(
      await db.isHabitDone(
        seedHabitId,
        DateTime(today.year, today.month, today.day),
      ),
      isTrue,
      reason: '打卡记录写入',
    );

    // 再点行主体 = 取消打卡（toggle）
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('今日未打卡'), findsOneWidget, reason: '再次点击取消打卡');
    expect(
      await db.isHabitDone(
        seedHabitId,
        DateTime(today.year, today.month, today.day),
      ),
      isFalse,
      reason: '记录已删除',
    );
  });

  testWidgets('新建习惯：未选图标时提示并禁用创建，点选后创建落库', (tester) async {
    await db.ensureDefaultList();
    await pumpHabitPage(tester);

    // 打开新建弹窗，弹窗内应展示图标选择区
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('新建习惯'), findsOneWidget);
    expect(find.text('图标'), findsOneWidget);
    expect(find.text('请点选一个图标'), findsOneWidget,
        reason: '未选图标时应提示必选');

    // 输入名称后仍不选图标——创建按钮保持禁用
    await tester.enterText(find.byType(TextField), '晨跑');
    await tester.pumpAndSettle();
    var createBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '创建'),
    );
    expect(createBtn.onPressed, isNull, reason: '未选图标时创建按钮禁用');

    // 点开独立图标选择弹窗（入口「选择图标」），点选 📚 后返回
    await tester.tap(find.text('选择图标'));
    await tester.pumpAndSettle();
    expect(find.text('选择图标'), findsNWidgets(2),
        reason: '弹窗标题 + 表单入口同时存在');
    await tester.tap(find.text('📚'));
    await tester.pumpAndSettle();
    expect(find.text('请点选一个图标'), findsNothing, reason: '选图标后提示消失');
    createBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '创建'),
    );
    expect(createBtn.onPressed, isNotNull, reason: '选图标后创建按钮可用');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final habits = await db.getHabits();
    expect(habits, hasLength(1), reason: '创建成功');
    expect(habits.first.name, '晨跑');
    expect(habits.first.icon, '📚', reason: '点选的图标应落库');
  });

  testWidgets('新建习惯：不选图标点创建无效（不落库）', (tester) async {
    await db.ensureDefaultList();
    await pumpHabitPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '阅读');
    await tester.pumpAndSettle();

    // 不选图标直接点创建——按钮禁用，弹窗不关闭、不落库
    final createBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '创建'),
    );
    expect(createBtn.onPressed, isNull, reason: '未选图标时创建按钮禁用');
    await tester.tap(find.text('创建'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('新建习惯'), findsOneWidget, reason: '弹窗保持打开');
    expect(await db.getHabits(), isEmpty, reason: '未落库');
  });

  testWidgets('长按编辑习惯：可修改名称与图标', (tester) async {
    await seedHabit();
    await pumpHabitPage(tester);

    // 长按习惯行打开操作底栏，点「编辑习惯」
    await tester.longPress(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('编辑习惯'), findsOneWidget);
    await tester.tap(find.text('编辑习惯'));
    await tester.pumpAndSettle();

    // 修改名称，并通过「更换图标」入口在独立弹窗里换图标
    await tester.enterText(find.byType(TextField), '晨读');
    await tester.tap(find.text('更换图标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🏊'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final updated = await db.getHabit(seedHabitId);
    expect(updated!.name, '晨读', reason: '名称应更新');
    expect(updated.icon, '🏊', reason: '图标应更新');
  });

  testWidgets('删除习惯：确认后删除，撤销条可恢复习惯与打卡记录', (tester) async {
    await seedHabit();
    final today = DateTime.now();
    await db.checkHabit(
      seedHabitId,
      DateTime(today.year, today.month, today.day),
    );
    await db.checkHabit(
      seedHabitId,
      DateTime(today.year, today.month, today.day - 1),
    );
    await pumpHabitPage(tester);

    // 长按 → 删除习惯 → 确认
    await tester.longPress(find.text('阅读'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除习惯'));
    await tester.pumpAndSettle();
    expect(find.text('删除习惯？'), findsOneWidget, reason: '确认弹窗');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 已删除：列表空 + 撤销条
    expect(find.text('还没有习惯，点 + 添加'), findsOneWidget, reason: '列表已空');
    expect(find.text('已删除「阅读」'), findsOneWidget, reason: '撤销条提示');
    expect(await db.getHabits(), isEmpty, reason: 'DB 已删除');

    // 点撤销 → 习惯与 2 条打卡记录完整恢复
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    final habits = await db.getHabits();
    expect(habits, hasLength(1), reason: '撤销后习惯恢复');
    expect(habits.first.id, seedHabitId, reason: '按原 ID 恢复');
    final records = await db.getHabitRecords(seedHabitId);
    expect(records, hasLength(2), reason: '撤销后打卡记录恢复');
    expect(find.text('阅读'), findsOneWidget, reason: '列表恢复显示');
  });

  testWidgets('连续打卡天数：连续 3 天显示连续打卡 3 天', (tester) async {
    await seedHabit();
    final today = DateTime.now();
    await db.checkHabit(
      seedHabitId,
      DateTime(today.year, today.month, today.day - 2),
    );
    await db.checkHabit(
      seedHabitId,
      DateTime(today.year, today.month, today.day - 1),
    );
    await db.checkHabit(
      seedHabitId,
      DateTime(today.year, today.month, today.day),
    );
    await pumpHabitPage(tester);

    expect(find.textContaining('连续打卡 3 天'), findsOneWidget,
        reason: '连续 3 天打卡');
    expect(find.textContaining('共打卡 3 天'), findsOneWidget);
  });
}
