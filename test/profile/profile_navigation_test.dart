import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/backup_types.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/profile_page.dart';

class _EmptyBackupService extends BackupService {
  _EmptyBackupService(super.db);

  @override
  Future<List<BackupFileInfo>> listBackupInfos() async => [];
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    NotificationService.instance.debugOverridePermission = null;
    NotificationService.instance.debugOverrideExactAlarm = null;
    await db.close();
  });

  Future<void> showProfile(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          backupServiceProvider.overrideWithValue(_EmptyBackupService(db)),
        ],
        child: const MaterialApp(home: ProfilePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('备份入口统一跳转到导出、导入和 WebDAV 页面', (tester) async {
    NotificationService.instance.debugOverridePermission = true;
    await showProfile(tester);

    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('导出备份'), findsNothing);
    expect(find.text('导入备份'), findsNothing);
    expect(find.text('WebDAV 云备份'), findsNothing);
    expect(find.text('开启通知权限'), findsNothing);

    await tester.tap(find.text('备份与恢复'));
    await tester.pumpAndSettle();

    expect(find.text('导出到文件'), findsOneWidget);
    expect(find.text('从文件导入'), findsOneWidget);
    expect(find.text('WebDAV 云备份'), findsOneWidget);
    expect(find.text('本地备份'), findsOneWidget);
  });

  testWidgets('提醒设置常驻精确闹钟与自启动入口并显示权限状态', (tester) async {
    NotificationService.instance.debugOverrideExactAlarm = false;
    await showProfile(tester);

    await tester.scrollUntilVisible(
      find.text('精确闹钟'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // 旧版通知权限修复入口已移除（8fe9ab1）
    expect(find.text('开启通知权限'), findsNothing);
    expect(find.text('发送测试通知'), findsNothing);
    // 常驻入口：精确闹钟 + 自启动，缺失时副标题提示打开系统设置
    expect(find.text('精确闹钟'), findsOneWidget);
    expect(find.text('自启动'), findsOneWidget);
    expect(find.text('未开启，点此打开系统设置'), findsOneWidget);

    // 系统设置中授权后回前台 → 重新检测并显示已开启
    NotificationService.instance.debugOverrideExactAlarm = true;
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pumpAndSettle();
    expect(find.text('未开启，点此打开系统设置'), findsNothing);
    expect(find.text('已开启'), findsOneWidget);
  });
}
