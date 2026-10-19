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

  testWidgets('通知权限缺失时才显示修复入口', (tester) async {
    NotificationService.instance.debugOverridePermission = false;
    await showProfile(tester);

    await tester.scrollUntilVisible(
      find.text('开启通知权限'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('自启动'), findsOneWidget);
    expect(find.text('开启通知权限'), findsOneWidget);
    expect(find.text('发送测试通知'), findsNothing);

    NotificationService.instance.debugOverridePermission = true;
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pumpAndSettle();
    expect(find.text('开启通知权限'), findsNothing);
  });
}
