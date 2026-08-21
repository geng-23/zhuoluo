import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/pomodoro_controller.dart';
import 'package:zhuoluo/features/profile/pomodoro_page.dart';

import '../support/fake_notification_scheduler.dart';

/// 番茄专注页：UI 状态流转 + 返回后计时不中断（进程级控制器）
///
/// 注意：计时运行中存在 1s 周期 Timer，避免 pumpAndSettle（会超时），
/// 一律用显式 pump；tearDown 由 container.dispose 取消计时器。
void main() {
  late AppDatabase db;
  late FakeNotificationScheduler fake;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
    SoundService.enabled = false;
    container = ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  /// 启动壳：首页一个按钮 push 番茄页（保证可返回；MaterialApp 提供
  /// ScaffoldMessenger 供 SnackBar）
  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PomodoroPage()),
                  ),
                  child: const Text('打开番茄'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 打开番茄页。[running] = 计时已在进行：路由过渡期间页面 watch 活跃，
  /// 不能用 pumpAndSettle（1s 周期 Timer 会使其超时），改显式推进；
  /// 空闲态则用 pumpAndSettle 等待过渡完成。
  Future<void> openPage(WidgetTester tester, {bool running = false}) async {
    await tester.tap(find.text('打开番茄'));
    if (running) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  /// 结束测试体前取消周期计时器（flutter_test 要求测试体结束时无挂起 Timer；
  /// tearDown 的 container.dispose 晚于该检查，必须在体内停表）
  void stopTimer() {
    container.read(pomodoroControllerProvider.notifier).pause();
  }

  testWidgets('开始 → 运行态显示暂停/结束，通知栏发出倒计时', (tester) async {
    await pumpShell(tester);
    await openPage(tester);
    expect(find.text('25:00'), findsOneWidget);
    await tester.tap(find.text('开始'));
    await tester.pump();
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('结束'), findsOneWidget);
    expect(fake.countdownShows, isNotEmpty, reason: '开始即显示倒计时通知');
    expect(fake.countdownShows.last.running, isTrue);
    stopTimer();
  });

  testWidgets('返回后计时不中断，重进页面仍显示进行中', (tester) async {
    await pumpShell(tester);
    await openPage(tester);
    await tester.tap(find.text('开始'));
    await tester.pump();
    // 返回首页（pop 过渡约 300ms；页面在过渡期间仍挂载，显式推进）
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final controller = container.read(pomodoroControllerProvider.notifier);
    expect(controller.state.state, PomodoroState.running,
        reason: '返回页面后计时继续（进程级控制器持有）');
    // 重新进入：仍显示进行中状态
    await openPage(tester, running: true);
    expect(find.text('暂停'), findsOneWidget);
    expect(controller.state.state, PomodoroState.running);
    expect(find.text('25:00'), findsOneWidget);
    stopTimer();
  });

  testWidgets('空闲态可切换时长，运行中禁用', (tester) async {
    await pumpShell(tester);
    await openPage(tester);
    await tester.tap(find.text('45 分'));
    await tester.pump();
    expect(find.text('45:00'), findsOneWidget, reason: '空闲态切换时长同步倒计时');
    await tester.tap(find.text('开始'));
    await tester.pump();
    final c = container.read(pomodoroControllerProvider.notifier);
    expect(c.state.minutes, 45);
    await tester.tap(find.text('15 分'));
    await tester.pump();
    expect(c.state.minutes, 45, reason: '运行中不可改时长');
    stopTimer();
  });

  testWidgets('暂停/继续/重新开始按钮流转', (tester) async {
    await pumpShell(tester);
    await openPage(tester);
    await tester.tap(find.text('开始'));
    await tester.pump();
    await tester.tap(find.text('暂停'));
    await tester.pump();
    expect(find.text('继续'), findsOneWidget);
    expect(find.text('重新开始'), findsOneWidget);
    expect(fake.countdownShows.last.running, isFalse,
        reason: '暂停态通知显示继续按钮');
    await tester.tap(find.text('继续'));
    await tester.pump();
    expect(find.text('暂停'), findsOneWidget);
    // 重新开始仅暂停态显示：先暂停再重新开始
    await tester.tap(find.text('暂停'));
    await tester.pump();
    await tester.tap(find.text('重新开始'));
    await tester.pump();
    expect(find.text('暂停'), findsOneWidget);
    expect(
      container.read(pomodoroControllerProvider.notifier).state.remainingSeconds,
      25 * 60,
      reason: '重新开始恢复满剩余',
    );
    stopTimer();
  });

  testWidgets('结束 → 回空闲态并提示（写记录、清通知）', (tester) async {
    await pumpShell(tester);
    await openPage(tester);
    await tester.tap(find.text('开始'));
    await tester.pump();
    await tester.tap(find.text('结束'));
    // finish 含真实 DB 写库：让真实异步收敛（broadcast 流投递 + SnackBar 入场）
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // 结束后计时器已取消，可安全 settle（SnackBar 显示期间无排帧）
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget, reason: '结束后回空闲态');
    expect(find.text('专注已结束'), findsOneWidget, reason: '立即结束提示 0 分钟');
    expect(fake.cancelled, contains(NotificationIds.forPomodoro),
        reason: '结束清理倒计时通知');
    final rows = await db.getPomodoros();
    expect(rows.single.durationMinutes, 0);
  });
}
