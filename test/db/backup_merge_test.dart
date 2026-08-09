import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/backup_types.dart';

/// 备份方案设计 2026-08-08 回归测试：
/// 文件名随机后缀 / 合并导入（去重 + 外键重映射 + 原子性）/ 自动备份门控与失败标志
void main() {
  final now = DateTime(2026, 8, 8, 10, 0, 0);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// 在内存库中播种基础数据（2 清单、2 任务、1 子任务、提醒、习惯、打卡、番茄）
  Future<void> seed(AppDatabase d) async {
    await d.ensureDefaultList();
    final inbox = await d.getDefaultList();
    final workId = await d.insertList('工作', '#FF0000', 1);
    final t1 = await d.insertTask(TasksCompanion.insert(
      listId: inbox.id,
      title: '交报告',
      createdAt: now,
    ));
    await d.insertTask(TasksCompanion.insert(
      listId: workId,
      title: '开会',
      createdAt: now,
    ));
    final sub = await d.insertTask(TasksCompanion.insert(
      listId: workId,
      parentId: Value(t1),
      title: '整理资料',
      createdAt: now,
    ));
    await d.insertReminder(
      RemindersCompanion.insert(taskId: t1, remindMinutesBefore: const Value(10)),
    );
    // 重复实例完成记录（task_completions 表）
    await d.completeInstance(sub, now);
    await d.insertException(
      TaskExceptionsCompanion.insert(
        taskId: t1,
        instanceDate: now,
        action: const Value('skip'),
      ),
    );
    final habitId = await d.insertHabit('阅读', '⭐', null);
    await d.checkHabit(habitId, now);
    await d.insertPomodoro(
      t1,
      25,
      now,
    );  }

  group('备份文件名随机后缀', () {
    test('同秒生成两次文件名后缀不同', () {
      final a = backupFileName(now);
      final b = backupFileName(now);
      expect(a, isNot(b), reason: '随机后缀防同秒覆盖');
      expect(a, startsWith('zhuoluo_backup_20260808_100000_'));
      expect(a, endsWith('.json'));
      expect(a.length, b.length);
    });
  });

  group('合并导入', () {
    test('标题去重 + 外键链重映射（listId/parentId/taskId/habitId）', () async {
      await seed(db);
      final backup = await BackupService(db).exportJson();
      // 目标库：仅默认清单 + 一个同名任务（"交报告"应去重跳过）
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      final targetInbox = await target.getDefaultList();
      await target.insertTask(TasksCompanion.insert(
        listId: targetInbox.id,
        title: '交报告',
        createdAt: now,
      ));

      final count = await BackupService(target).importJson(backup, merge: true);
      expect(count, 3, reason: '备份 3 任务全部参与合并');

      // 同名任务去重：交报告不应重复
      final lists = await target.getAllLists();
      expect(lists.length, 2, reason: '新增"工作"清单，同名清单不重复');
      final tasks = await target.allTasksForBackup();
      final reports = tasks.where((t) => t.title == '交报告').toList();
      expect(reports.length, 1, reason: '同名任务按标题去重');
      final workList = lists.firstWhere((l) => l.name == '工作');
      final meeting = tasks.firstWhere((t) => t.title == '开会');
      expect(meeting.listId, workList.id, reason: '清单外键重映射');
      final sub = tasks.firstWhere((t) => t.title == '整理资料');
      expect(sub.parentId, reports.single.id, reason: '父任务外键重映射');

      // 提醒/例外/打卡/番茄随任务重映射
      final reminders = await target.allRemindersForBackup();
      expect(reminders.single.taskId, reports.single.id);
      final exceptions = await target.allExceptionsForBackup();
      expect(exceptions.single.taskId, reports.single.id);
      final completions = await target.allCompletionsForBackup();
      expect(completions.single.taskId, sub.id);
      final pomodoros = await target.getPomodoros();
      expect(pomodoros.single.taskId, reports.single.id);
      final habits = await target.getHabits();
      expect(habits.single.name, '阅读');
      final records = await target.getAllHabitRecords();
      expect(records.single.habitId, habits.single.id);
    });

    test('重复内容再次合并不产生重复', () async {
      await seed(db);
      final backup = await BackupService(db).exportJson();
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await BackupService(target).importJson(backup, merge: true);
      // 第二次合并同一份备份 → 全部去重
      await BackupService(target).importJson(backup, merge: true);
      expect((await target.getAllLists()).length, 2);
      expect((await target.allTasksForBackup()).length, 3);
      expect((await target.allRemindersForBackup()).length, 1);
      expect((await target.allCompletionsForBackup()).length, 1);
      expect((await target.allExceptionsForBackup()).length, 1);
      expect((await target.getAllHabitRecords()).length, 1);
      // 番茄记录设计为"直接追加"（无去重键），两次合并 → 2 条
      expect((await target.getPomodoros()).length, 2);
    });

    test('同名但计划时间不同 → 都保留（不误去重）', () async {
      await seed(db);
      final backup = await BackupService(db).exportJson();
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      final inbox = await target.getDefaultList();
      // 目标库同名"交报告"（10:00 有计划时间），备份里同名无计划时间
      await target.insertTask(TasksCompanion.insert(
        listId: inbox.id,
        title: '交报告',
        planStart: Value(now),
        planEnd: Value(now.add(const Duration(hours: 1))),
        createdAt: now,
      ));
      await BackupService(target).importJson(backup, merge: true);
      final tasks = await target.allTasksForBackup();
      expect(
        tasks.where((t) => t.title == '交报告').length,
        2,
        reason: '同名但计划时间不同应保留为两个独立任务（内容指纹去重）',
      );
    });

    test('同名但备注不同 → 都保留（不误去重）', () async {
      await seed(db);
      final backup = await BackupService(db).exportJson();
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      final inbox = await target.getDefaultList();
      await target.insertTask(TasksCompanion.insert(
        listId: inbox.id,
        title: '交报告',
        note: const Value('重要'),
        createdAt: now,
      ));
      await BackupService(target).importJson(backup, merge: true);
      final tasks = await target.allTasksForBackup();
      expect(
        tasks.where((t) => t.title == '交报告').length,
        2,
        reason: '同名但备注不同应保留为两个独立任务',
      );
    });

    test('本地同清单多个同名 + 备份同名同内容 → 去重跳过不崩溃', () async {
      await seed(db);
      final backup = await BackupService(db).exportJson();
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      final inbox = await target.getDefaultList();
      // 本地同清单两个同名"交报告"（此前 getSingleOrNull 会抛 Too many elements）
      for (var i = 0; i < 2; i++) {
        await target.insertTask(TasksCompanion.insert(
          listId: inbox.id,
          title: '交报告',
          createdAt: now,
        ));
      }
      await BackupService(target).importJson(backup, merge: true);
      final tasks = await target.allTasksForBackup();
      expect(
        tasks.where((t) => t.title == '交报告').length,
        2,
        reason: '本地多个同名任务 + 备份同名同内容：去重跳过，不崩溃不新增',
      );
    });

    test('本地多个同名清单 → 合并不崩溃', () async {
      await seed(db);
      final backup = await BackupService(db).exportJson();
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      // 本地两个同名"工作"清单
      await target.insertList('工作', '#111111', 0);
      await target.insertList('工作', '#222222', 1);
      await BackupService(target).importJson(backup, merge: true);
      final lists = await target.getAllLists();
      expect(
        lists.where((l) => l.name == '工作').length,
        2,
        reason: '本地多个同名清单 + 备份同名清单：去重取首行不崩溃',
      );
    });

    test('原子性：中途失败整体回滚（坏任务标题类型）', () async {
      await seed(db);
      final backup = jsonDecode(await BackupService(db).exportJson())
          as Map<String, dynamic>;
      // 注入一条非法任务（title 非字符串）→ 解析阶段抛 TypeError
      (backup['tasks'] as List).add({
        'id': 999,
        'listId': 1,
        'title': 123,
        'note': '',
        'quadrant': 4,
        'isAllDay': false,
        'color': '',
        'rrule': '',
        'hasReminder': false,
        'hasNote': false,
        'sortOrder': 0,
        'skippedDates': '[]',
        'createdAt': now.toIso8601String(),
      });
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      await target.insertTask(TasksCompanion.insert(
        listId: (await target.getDefaultList()).id,
        title: '保留我',
        createdAt: now,
      ));
      await expectLater(
        BackupService(target).importJson(jsonEncode(backup), merge: true),
        throwsA(anything),
      );
      // 回滚：原数据完整保留，未被部分合并
      final tasks = await target.allTasksForBackup();
      expect(tasks.single.title, '保留我');
      expect((await target.getAllLists()).length, 1);
    });

    test('设置项覆盖写入', () async {
      await db.ensureDefaultList();
      await db.setSetting('themeMode', 'dark');
      final backup = await BackupService(db).exportJson();
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      await target.setSetting('themeMode', 'light');
      await BackupService(target).importJson(backup, merge: true);
      expect(await target.getSetting('themeMode'), 'dark');
    });

    test('备份含多个默认清单时合并不产生新的默认清单', () async {
      await db.ensureDefaultList();
      final workId = await db.insertList('工作', '#FF0000', 1);
      // 模拟旧版本/手工备份的脏数据：另一个清单也标记为默认
      await (db.update(db.lists)..where((l) => l.id.equals(workId))).write(
        const ListsCompanion(isDefault: Value(true)),
      );
      final backup = await BackupService(db).exportJson();

      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await target.ensureDefaultList();
      final count = await BackupService(target).importJson(backup, merge: true);
      expect(count, greaterThanOrEqualTo(0), reason: '导入事务本身成功');

      // 修复前：合并插入的"工作"清单继承 isDefault=true → 两个默认清单
      // → getDefaultList 抛 StateError（事务已提交却报"导入失败"）
      final defaults = (await target.getAllLists())
          .where((l) => l.isDefault)
          .toList();
      expect(defaults, hasLength(1),
          reason: '合并导入后默认清单必须唯一');
      final work = (await target.getAllLists())
          .firstWhere((l) => l.name == '工作');
      expect(work.isDefault, isFalse, reason: '新导入清单不继承默认标记');
      await expectLater(
        target.getDefaultList(),
        completes,
        reason: 'getDefaultList 不再抛 StateError',
      );
    });
  });

  group('自动备份', () {
    test('24h 内门控：lastAutoBackupAt 存在且 <24h → 直接返回不重复执行', () async {
      await db.ensureDefaultList();
      await db.setSetting(
        BackupService.keyLastAutoBackupAt,
        DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      );
      // 测试环境无 path_provider 通道，若执行到写盘必然失败 →
      // 若返回 true 说明被门控短路，未触碰平台层
      final ok = await BackupService(db).autoBackup();
      expect(ok, isTrue);
      expect(await db.getSetting(BackupService.keyAutoBackupFailed), isNull);
    });

    test('超过 24h → 执行写盘，测试环境失败写入失败标志', () async {
      await db.ensureDefaultList();
      await db.setSetting(
        BackupService.keyLastAutoBackupAt,
        DateTime.now().subtract(const Duration(days: 2)).toIso8601String(),
      );
      final ok = await BackupService(db).autoBackup();
      // 测试环境（VM）path_provider 无通道 → 写盘失败 → false + 失败标志
      expect(ok, isFalse);
      final fail = await db.getSetting(BackupService.keyAutoBackupFailed);
      expect(fail, isNotNull);
      final decoded = jsonDecode(fail!) as Map<String, dynamic>;
      expect(decoded['time'], isNotNull);
      expect(decoded['error'], isNotNull);
    });

    test('无 lastAutoBackupAt（首次打开）→ 执行自动备份', () async {
      await db.ensureDefaultList();
      final ok = await BackupService(db).autoBackup();
      expect(ok, isFalse, reason: '测试环境写盘失败');
      expect(await db.getSetting(BackupService.keyAutoBackupFailed), isNotNull);
    });
  });
}
