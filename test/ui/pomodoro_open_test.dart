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
}
