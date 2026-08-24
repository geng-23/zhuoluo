import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/backup_types.dart';

/// 备份方案 A 回归测试（系统文件选择器导出/导入 + 冲突增强）
void main() {
  final now = DateTime.now();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed() async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final taskId = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '任务A',
      createdAt: now,
    ));
    await db.insertReminder(
      RemindersCompanion.insert(
        taskId: taskId,
        remindMinutesBefore: const Value(10),
      ),
    );
    await db.insertHabit('阅读', '⭐', null);
    await db.completeTask(taskId);
  }

  test('parseBackupStats：解析备份内容统计（确认框/完成报告用）', () async {
    await seed();
    final service = BackupService(db);
    final json = await service.exportJson();

    final stats = service.parseBackupStats(json);
    expect(stats, isNotNull);
    expect(stats!.lists, 1);
    expect(stats.tasks, 1);
    expect(stats.reminders, 1);
    // 普通任务完成只设 completedAt，不产生实例完成记录
    expect(stats.completions, 0);
    expect(stats.habits, 1);
  });

  test('parseBackupStats：非法 JSON / 非着落备份返回 null', () {
    final service = BackupService(db);
    expect(service.parseBackupStats('not json'), isNull);
    expect(service.parseBackupStats('{"version": 99, "tasks": []}'), isNull);
    expect(service.parseBackupStats('{"version": 1, "tasks": "x"}'), isNull);
  });

  test('exportToUserLocation 数据源正确（导出→导入往返完整）', () async {
    await seed();
    final service = BackupService(db);
    final json = await service.exportJson();

    // 模拟"导出到用户位置"后，用另一台设备（新库）从该内容导入
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    final count = await BackupService(db2).importJson(json);
    expect(count, 1);
    final tasks = await db2.getAllUncompleted();
    expect(tasks, isEmpty, reason: '任务已完成后导入保持完成态');
    final habits = await db2.getHabits();
    expect(habits.single.name, '阅读');
    final reminders = await db2.getReminders(
      (await db2.allTasksForBackup()).single.id,
    );
    expect(reminders.single.remindMinutesBefore, 10);
  });

  test('恢复前自动备份：exportJson 数据完整（安全网内容）', () async {
    await seed();
    final service = BackupService(db);
    // 恢复前自动备份 = 导出当前完整数据；导入回滚后可恢复原状
    final json = await service.exportJson();
    final stats = service.parseBackupStats(json);
    expect(stats!.tasks, 1);
    expect(stats.reminders, 1);

    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await BackupService(db2).importJson(json);
    final tasks = await db2.allTasksForBackup();
    expect(tasks.single.title, '任务A');
  });

  test(
    '导入读取必须用 readAsBytes+utf8.decode：XFile.fromData 中文不乱码'
    '（readAsString 按 code unit 解读字节，中文必乱码）',
    () async {
      await seed();
      final service = BackupService(db);
      final json = await service.exportJson();
      // 模拟 file_selector_android 的 openFile 返回：XFile.fromData(原始字节)
      final xfile = XFile.fromData(
        utf8.encode(json),
        mimeType: 'application/json',
      );
      // 修复后的读取方式（backup_platform_io pickBackupFileImpl 同款）
      final text = utf8.decode(await xfile.readAsBytes());
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      await BackupService(db2).importJson(text);
      final lists = await db2.getAllLists();
      expect(lists.single.name, '收件箱');
      final tasks = await db2.allTasksForBackup();
      expect(tasks.single.title, '任务A');
    },
  );

  group('删除备份与自动备份计时重置', () {
    test('删除后无任何备份文件 → 重置 lastAutoBackupAt（下次打开补一份）', () async {
      await db.ensureDefaultList();
      await db.setSetting(
        BackupService.keyLastAutoBackupAt,
        DateTime.now().toIso8601String(),
      );
      final service = _InjectingBackupService(db)..remaining = [];
      await service.deleteBackupFiles(['/nonexistent/a.json']);
      expect(await db.getSetting(BackupService.keyLastAutoBackupAt), '',
          reason: '备份删光后重置计时，24h 门控不再拦截');
    });

    test('删除后仍有备份文件 → 不重置计时', () async {
      await db.ensureDefaultList();
      final old =
          DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();
      await db.setSetting(BackupService.keyLastAutoBackupAt, old);
      final service = _InjectingBackupService(db)
        ..remaining = [
          BackupFileInfo(
            path: '/x/zhuoluo_backup_1.json',
            name: 'zhuoluo_backup_1.json',
            modified: DateTime.now(),
            size: 100,
          ),
        ];
      await service.deleteBackupFiles(['/nonexistent/a.json']);
      expect(await db.getSetting(BackupService.keyLastAutoBackupAt), old,
          reason: '仍有备份时保持计时，一天最多一次');
    });
  });
  group('备份完整性与导入字段校验', () {
    /// 导出一份含基础数据的备份并解码为可编辑结构
    Future<Map<String, dynamic>> exported() async {
      await seed();
      final json = await BackupService(db).exportJson();
      return jsonDecode(json) as Map<String, dynamic>;
    }

    AppDatabase newDb() {
      final d = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(d.close);
      return d;
    }

    test('导出包含 checksum 字段且往返导入成功', () async {
      final data = await exported();
      expect(data['checksum'], isA<String>());
      final count = await BackupService(newDb()).importJson(jsonEncode(data));
      expect(count, 1, reason: '合法备份带校验和正常导入');
    });

    test('checksum 与内容不符（被篡改）→ 整体拒绝', () async {
      final data = await exported();
      (data['tasks'] as List).first['title'] = '篡改后的标题';
      await expectLater(
        BackupService(newDb()).importJson(jsonEncode(data)),
        throwsA(isA<FormatException>()),
        reason: '载荷被修改后重算校验和必然不匹配，导入须拒绝',
      );
    });

    test('旧版备份无 checksum 字段 → 兼容导入', () async {
      final data = await exported()..remove('checksum');
      final count = await BackupService(newDb()).importJson(jsonEncode(data));
      expect(count, 1, reason: '历史版本备份保持向后兼容');
    });

    test('remindAtMinutes 越界（>1439 或负数）→ 拒绝', () async {
      for (final bad in [1440, -1]) {
        final data = await exported()..remove('checksum');
        (data['reminders'] as List).first['remindAtMinutes'] = bad;
        await expectLater(
          BackupService(newDb()).importJson(jsonEncode(data)),
          throwsA(isA<FormatException>()),
          reason: '全天提醒时刻必须为当日 0-1439 分钟，越界值 $bad 拒绝落库',
        );
      }
    });

    test('remindMinutesBefore 越界（负数 / >31 天）→ 拒绝', () async {
      for (final bad in [-5, 44641]) {
        final data = await exported()..remove('checksum');
        (data['reminders'] as List).first['remindMinutesBefore'] = bad;
        await expectLater(
          BackupService(newDb()).importJson(jsonEncode(data)),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('非法 RRULE（未知频率/未知参数/数值越界）→ 拒绝', () async {
      const badRules = [
        'FREQ=SECONDLY',
        'FREQ=DAILY;EVIL=1',
        'FREQ=DAILY;INTERVAL=0',
        'FREQ=DAILY;COUNT=-3',
        'INTERVAL=2',
        'FREQ=WEEKLY;BYDAY=XX',
        'FREQ=MONTHLY;BYMONTHDAY=32',
        'FREQ=DAILY;UNTIL=notadate',
      ];
      for (final rule in badRules) {
        final data = await exported()..remove('checksum');
        (data['tasks'] as List).first['rrule'] = rule;
        await expectLater(
          BackupService(newDb()).importJson(jsonEncode(data)),
          throwsA(isA<FormatException>()),
          reason: '畸形重复规则「$rule」须在导入时白名单拦截',
        );
      }
    });

    test('skippedDates 格式非法或条目过多 → 拒绝', () async {
      for (final bad in ['not-json', '[123]', '["${DateTime(2026)}x"]']) {
        final data = await exported()..remove('checksum');
        (data['tasks'] as List).first['skippedDates'] = bad;
        await expectLater(
          BackupService(newDb()).importJson(jsonEncode(data)),
          throwsA(isA<FormatException>()),
          reason: '跳过日期载荷「$bad」非法',
        );
      }
      final big = jsonEncode(
        List.generate(10001, (i) => DateTime(2026, 1 + i % 12, 1 + i % 28)
            .toIso8601String()),
      );
      final data = await exported()..remove('checksum');
      (data['tasks'] as List).first['skippedDates'] = big;
      await expectLater(
        BackupService(newDb()).importJson(jsonEncode(data)),
        throwsA(isA<FormatException>()),
        reason: '超过 10000 条的跳过日期载荷拒绝导入',
      );
    });
  });

  group('自动备份清理域隔离', () {
    test('保留份数清理只删私有域文件，手动导出的旧备份不被误删', () async {
      await db.ensureDefaultList();
      final base = DateTime.now();
      final service = _IsolationBackupService(db);
      // 私有域：11 份自动备份（新 → 旧）
      for (var i = 0; i < 11; i++) {
        service.autoDir.add(
          BackupFileInfo(
            path: '/private/zhuoluo_backup_$i.json',
            name: 'zhuoluo_backup_$i.json',
            modified: base.subtract(Duration(minutes: i)),
            size: 10,
          ),
        );
      }
      // 手动导出域：一份远早于全部自动备份的旧文件——若清理误用全量视图
      // 计数，该文件会因"更旧"被当作第 12 份删除
      service.manualFiles.add(
        BackupFileInfo(
          path: '/Download/着落/manual_old.json',
          name: 'manual_old.json',
          modified: base.subtract(const Duration(days: 365)),
          size: 10,
        ),
      );
      final ok = await service.autoBackup();
      expect(ok, isTrue, reason: '测试替身写盘成功，自动备份应完整执行');
      expect(service.wroteAutoBackup, isTrue);
      // 只删私有域内最旧一份；手动导出文件不在删除列表
      expect(service.deletedPaths, ['/private/zhuoluo_backup_10.json'],
          reason: '清理只作用于自动备份私有目录（保留 10 份）');
    });
  });
}

/// 隔离测试替身：私有域/全量视图分离注入，拦截写盘与删除动作。
/// [listBackupInfos] 故意返回"私有域 + 手动导出域"的并集——若实现回退为
/// 用全量视图做清理计数，manual 文件会被误删导致用例失败。
class _IsolationBackupService extends BackupService {
  _IsolationBackupService(super.db);

  /// 自动备份私有目录内容（listAutoBackupInfos 的返回基准）
  final List<BackupFileInfo> autoDir = [];

  /// 用户手动导出的备份（只出现在全量视图中）
  final List<BackupFileInfo> manualFiles = [];

  final List<String> deletedPaths = [];
  bool wroteAutoBackup = false;

  @override
  Future<List<BackupFileInfo>> listAutoBackupInfos() async =>
      List.of(autoDir);

  @override
  Future<List<BackupFileInfo>> listBackupInfos() async =>
      [...autoDir, ...manualFiles];

  @override
  Future<String> writeAutoBackupFile(String json) async {
    wroteAutoBackup = true;
    return '/private/fake.json';
  }

  @override
  Future<void> deleteBackupFiles(List<String> paths) async {
    deletedPaths.addAll(paths);
  }
}

/// 测试替身：注入 listBackupInfos 结果，绕开测试环境
/// path_provider 无通道导致文件列表不可用的问题。
class _InjectingBackupService extends BackupService {
  _InjectingBackupService(super.db);

  List<BackupFileInfo> remaining = [];

  @override
  Future<List<BackupFileInfo>> listBackupInfos() async => remaining;
}
