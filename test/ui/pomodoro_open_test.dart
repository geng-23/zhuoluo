import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/pomodoro_native.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/pomodoro_page.dart';
import 'package:zhuoluo/shell/home_shell.dart';

import '../support/fake_notification_scheduler.dart';
import '../support/fake_pomodoro_native.dart';

/// 番茄钟通知主体点击 → HomeShell 导航到番茄专注页（原生桥 opens 事件）
void main() {
  late AppDatabase db;
  late FakeNotificationScheduler fake;
  late FakePomodoroNative native;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
    SoundService.enabled = false;
    native = FakePomodoroNative();
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        pomodoroNativeProvider.overrideWithValue(native),
      ],
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

  testWidgets('点击番茄钟通知主体 → 打开番茄专注页', (tester) async {
    await pumpShell(tester);
    expect(find.byType(PomodoroPage), findsNothing, reason: '初始不在番茄页');

    // 模拟原生 contentIntent 转发的 openPomodoro 事件
    native.emitOpen();
    await tester.pumpAndSettle();

    expect(find.byType(PomodoroPage), findsOneWidget, reason: '点击通知直达番茄页');
    expect(find.text('开始'), findsOneWidget, reason: '番茄页处于待开始态');
  });

  testWidgets('冷启动竞态：openPomodoro 先于订阅到达 → latch 补偿导航一次', (
    tester,
  ) async {
    // 事件先到（HomeShell 尚未挂载、无订阅者，broadcast 流丢弃事件）
    native.emitOpenBeforeSubscribe();

    await pumpShell(tester);
    await tester.pumpAndSettle();

    expect(find.byType(PomodoroPage), findsOneWidget,
        reason: 'initState 订阅后消费 latch 补偿导航');
  });

  testWidgets('同一事件不重复消费：流送达后 latch 已清', (tester) async {
    await pumpShell(tester);
    native.emitOpen();
    await tester.pumpAndSettle();
    expect(find.byType(PomodoroPage), findsOneWidget);

    // 流路径已送达并清除 latch：后续 HomeShell 重建时 initState 的
    // 补消费不得再触发一次导航
    expect(native.consumePendingOpen(), isFalse,
        reason: 'openPomodoro 事件经流处理后不得残留待消费标志');
  });
}
