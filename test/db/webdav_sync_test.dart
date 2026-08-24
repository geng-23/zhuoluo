import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/backup_types.dart';
import 'package:zhuoluo/data/services/webdav_service.dart';

import '../support/fake_webdav_service.dart';

void main() {
  late AppDatabase db;
  late _LocalStubBackupService service;
  late FakeWebdavService webdav;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = _LocalStubBackupService(db);
    webdav = FakeWebdavService();
    service.webdavFactory = () => webdav;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> configure({bool enabled = true}) =>
      service.writeWebdavConfig(WebdavConfig(
        url: 'https://dav.example.com/dav/',
        username: 'user',
        password: 'pass',
        dir: 'zhuoluo',
        enabled: enabled,
      ));

  test('未配置云端：自动备份不上传', () async {
    final ok = await service.autoBackup();
    expect(ok, isTrue);
    expect(webdav.uploadCalls, 0, reason: '从未配置时不得发起上传');
  });

  test('配置齐全且启用：本地备份成功后同一份 JSON 上传并写同步状态', () async {
    await configure();
    await db.ensureDefaultList();
    // 造一条任务让导出内容可断言
    final list = await db.getDefaultList();
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '买牛奶',
      createdAt: AppClock.now(),
    ));

    final ok = await service.autoBackup();
    expect(ok, isTrue);
    expect(webdav.uploadCalls, 1);
    final uploaded = jsonDecode(webdav.uploadedJson.single) as Map<String, dynamic>;
    expect(uploaded['version'], 1);
    expect((uploaded['tasks'] as List), hasLength(1));

    // 凭据与云端配置不进备份载荷
    final settings = (uploaded['settings'] as List).cast<Map>();
    expect(settings.where((s) => (s['key'] as String).startsWith('webdav')),
        isEmpty,
        reason: 'webdav 开头的设置键（含密码）必须被导出过滤');

    // 同步状态：成功时间已写、失败标志清空
    expect(await db.getSetting(BackupService.keyWebdavLastSyncAt), isNotEmpty);
    expect(await db.getSetting(BackupService.keyWebdavFailed), '');

    // 远端保留清理在每次成功上传后执行
    expect(webdav.listCalls, 1);
  });

  test('自动上传受开关限制：enabled=false 时每日自动路径不上传', () async {
    await configure(enabled: false);
    final ok = await service.autoBackup();
    expect(ok, isTrue);
    expect(webdav.uploadCalls, 0);
  });

  test('手动立即上传不受开关限制（requireEnabled=false）', () async {
    await configure(enabled: false);
    await db.ensureDefaultList();
    final json = await service.exportJson();
    final ok = await service.syncToWebdav(json, requireEnabled: false);
    expect(ok, isTrue);
    expect(webdav.uploadCalls, 1);
  });

  test('云端失败不影响本地备份成功状态，只记失败角标', () async {
    await configure();
    webdav.uploadError =
        const WebdavException('无法连接服务器，请检查网络与服务器地址');

    final ok = await service.autoBackup();
    expect(ok, isTrue, reason: '本地写盘成功即视为自动备份成功');
    expect(await db.getSetting(BackupService.keyLastAutoBackupAt), isNotEmpty,
        reason: '本地自动备份时间戳照常写入，24h 门控不被云端失败干扰');

    final failedRaw = await db.getSetting(BackupService.keyWebdavFailed);
    expect(failedRaw, isNotEmpty);
    expect(failedRaw, contains('无法连接服务器'));
    expect(await db.getSetting(BackupService.keyWebdavLastSyncAt), isNull);
  });

  test('远端保留最近 N 份：超出部分按修改时间从旧到新删除', () async {
    await configure();
    final base = DateTime(2026, 8, 24, 10);
    webdav.remoteSeed = [
      for (var i = 0; i < 12; i++)
        WebdavBackupInfo(
          name: 'zhuoluo_backup_old_${i.toString().padLeft(2, '0')}.json',
          modified: base.subtract(Duration(minutes: i)),
          size: 10,
        ),
    ];
    await db.ensureDefaultList();
    final json = await service.exportJson();
    await service.syncToWebdav(json);

    expect(webdav.deletedNames,
        ['zhuoluo_backup_old_10.json', 'zhuoluo_backup_old_11.json'],
        reason: '仅删除第 ${BackupService.keepBackupCount + 1} 份及更旧的远端备份');
  });

  test('远端不足 N 份时不删除任何文件', () async {
    await configure();
    webdav.remoteSeed = [
      WebdavBackupInfo(
        name: 'zhuoluo_backup_only.json',
        modified: DateTime(2026, 8, 1),
        size: 10,
      ),
    ];
    await db.ensureDefaultList();
    final json = await service.exportJson();
    await service.syncToWebdav(json);
    expect(webdav.deletedNames, isEmpty);
  });

  test('远端清理失败不影响本次同步结果', () async {
    await configure();
    // 让 list 抛异常：替身通过 uploadError 无法表达，改用真实服务子类
    final flaky = _FlakyListWebdav();
    service.webdavFactory = () => flaky;
    await db.ensureDefaultList();
    final json = await service.exportJson();
    final ok = await service.syncToWebdav(json);
    expect(ok, isTrue, reason: '列表/清理失败只记日志，不算同步失败');
    expect(flaky.uploadCount, 1);
    expect(await db.getSetting(BackupService.keyWebdavLastSyncAt), isNotEmpty);
  });
}

/// 隔离本地文件系统的自动备份替身（同 backup_test 模式）：
/// 写盘/私有目录列表/删除全部内存化，专注验证 WebDAV 同步编排。
class _LocalStubBackupService extends BackupService {
  _LocalStubBackupService(super.db);

  bool wroteAutoBackup = false;

  @override
  Future<String> writeAutoBackupFile(String json) async {
    wroteAutoBackup = true;
    return '/private/fake.json';
  }

  @override
  Future<List<BackupFileInfo>> listAutoBackupInfos() async => [];

  @override
  Future<List<BackupFileInfo>> listBackupInfos() async => [];

  @override
  Future<void> deleteBackupFiles(List<String> paths) async {}
}

/// 列表始终失败的替身：模拟远端清理环节异常
class _FlakyListWebdav extends FakeWebdavService {
  int uploadCount = 0;

  @override
  Future<String> upload(WebdavConfig c, String json) async {
    uploadCount++;
    return 'zhuoluo_backup_fake.json';
  }

  @override
  Future<List<WebdavBackupInfo>> list(WebdavConfig c) async {
    throw const WebdavException('服务器错误（HTTP 502），请稍后重试');
  }
}
