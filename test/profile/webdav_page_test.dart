import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/webdav_service.dart';
import 'package:zhuoluo/features/profile/webdav_page.dart';

import '../support/fake_webdav_service.dart';

/// WebDAV 云备份页：配置回填/保存持久化/测试连接反馈/手动上传/开关持久化
void main() {
  late AppDatabase db;
  late BackupService service;
  late FakeWebdavService webdav;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = BackupService(db);
    webdav = FakeWebdavService();
    service.webdavFactory = () => webdav;
  });

  tearDown(() async => db.close());

  Future<void> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        backupServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: WebdavPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('已保存配置回填到表单', (tester) async {
    await service.writeWebdavConfig(const WebdavConfig(
      url: 'https://dav.example.com/dav',
      username: 'alice',
      password: 'secret',
      dir: 'mydir',
      enabled: false,
    ));
    await pumpPage(tester);

    expect(find.text('https://dav.example.com/dav'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('mydir'), findsOneWidget);
    // 密码不回显明文（obscure），但开关状态应与配置一致
    final switchTile =
        tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(switchTile.value, isFalse);
    final passField = tester.widget<TextField>(
      find.widgetWithText(TextField, '密码 / 应用专用密码').first,
    );
    expect(passField.controller!.text, 'secret');
    expect(passField.obscureText, isTrue, reason: '密码默认打码显示');
  });

  testWidgets('测试连接（成功）反馈', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav/',
    );
    await tester.enterText(find.widgetWithText(TextField, '账号'), 'bob');
    await tester.enterText(
      find.widgetWithText(TextField, '密码 / 应用专用密码'),
      'pw',
    );
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.text('连接成功'), findsOneWidget);
    // 表单值直传服务（未保存也可先测试）
    expect(webdav.lastTestedConfig!.username, 'bob');
    // 未保存的表单值不写库
    expect(await db.getSetting(BackupService.keyWebdavUrl), isNull);
  });

  testWidgets('测试连接（失败）展示服务端语义化错误', (tester) async {
    webdav.testConnectionError = const WebdavException(
        '账号、密码或授权方式不正确（部分服务要求使用应用专用密码而非登录密码）');
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav/',
    );
    await tester.enterText(find.widgetWithText(TextField, '账号'), 'bob');
    await tester.enterText(
      find.widgetWithText(TextField, '密码 / 应用专用密码'),
      'wrong',
    );
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    // 页面 helper/标签也含「应用专用密码」，改用错误文案独有片段定位 snackbar
    expect(find.textContaining('授权方式不正确'), findsOneWidget,
        reason: '401 类失败应展示凭据提示文案');
  });

  testWidgets('立即上传：保存配置 + 上传成功 + 写同步时间', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav/',
    );
    await tester.enterText(find.widgetWithText(TextField, '账号'), 'carol');
    await tester.enterText(
      find.widgetWithText(TextField, '密码 / 应用专用密码'),
      'pw',
    );
    await tester.tap(find.text('立即上传'));
    await tester.pumpAndSettle();

    expect(webdav.uploadCalls, 1);
    expect(await db.getSetting(BackupService.keyWebdavUrl),
        'https://dav.example.com/dav/');
    expect(await db.getSetting(BackupService.keyWebdavUser), 'carol');
    expect(await db.getSetting(BackupService.keyWebdavLastSyncAt), isNotEmpty);
    expect(await db.getSetting(BackupService.keyWebdavFailed), '');
    expect(find.text('已上传到云端'), findsOneWidget);
  });

  testWidgets('每日自动上传开关持久化', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(await db.getSetting(BackupService.keyWebdavEnabled), 'false');
  });
}
