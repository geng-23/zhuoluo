import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/shell/home_shell.dart';

import '../support/fake_notification_scheduler.dart';

/// 记录型备份服务替身：只计数自动备份触发次数，不触碰文件系统
/// （测试环境无 path_provider 通道，写盘必然失败）。
class _CountingBackupService extends BackupService {
  _CountingBackupService(super.db);

  int autoBackupCalls = 0;

  @override
  Future<bool> autoBackup() async {
    autoBackupCalls++;
    return true;
  }
}

/// 回前台自动备份（进程常驻时"打开 App"）：
/// - 冷启动首个 resumed（无前置 paused）不触发——main() 已触发过
/// - 后台切回前台（paused → resumed）触发一次检查（24h 门控在服务内）
void main() {
  late AppDatabase db;
  late _CountingBackupService backup;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    backup = _CountingBackupService(db);
    SoundService.enabled = false;
    // 回前台 _onResume 会刷新权限缓存/检查重排，注入替身避免触碰平台插件
    NotificationService.instance.debugOverrideScheduler =
        FakeNotificationScheduler();
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await db.ensureDefaultList();
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        backupServiceProvider.overrideWithValue(backup),
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

  testWidgets('冷启动首个 resumed 不触发自动备份（main() 已触发过）', (tester) async {
    await pumpShell(tester);

    // 冷启动首个 resumed：无前置 paused，不应重复触发
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(backup.autoBackupCalls, 0,
        reason: '冷启动路径 main() 已调用过 autoBackup，首个 resumed 不重复触发');
  });

  testWidgets('后台切回前台（paused → resumed）触发一次自动备份', (tester) async {
    await pumpShell(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(backup.autoBackupCalls, 1,
        reason: '进程常驻时从后台切回前台应补触发自动备份检查');
  });

  testWidgets('多次后台切回前台每次都触发检查（24h 门控在服务内限流）', (tester) async {
    await pumpShell(tester);

    for (var i = 0; i < 3; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(backup.autoBackupCalls, 3,
        reason: '每次回前台都触发检查；实际写盘频率由服务内 24h 门控限制');
  });

  testWidgets('仅 inactive（通知栏下拉/权限弹窗）不算后台，回前台不触发', (tester) async {
    await pumpShell(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(backup.autoBackupCalls, 0,
        reason: 'inactive 不置后台标记，仅临时失去焦点不算"打开 App"');
  });
}
