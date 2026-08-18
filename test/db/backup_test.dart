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
}

/// 测试替身：注入 listBackupInfos 结果，绕开测试环境
/// path_provider 无通道导致文件列表不可用的问题。
class _InjectingBackupService extends BackupService {
  _InjectingBackupService(super.db);

  List<BackupFileInfo> remaining = [];

  @override
  Future<List<BackupFileInfo>> listBackupInfos() async => remaining;
}
