import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

/// 重复任务一致性测试：
/// - completeInstance 幂等（崩溃修复）
/// - UNIQUE 约束（防重复记录）
/// - pruneCompletionsForTask（系列改期清理旧完成记录）
/// - v2 → v3 迁移去重
void main() {
  late Directory tempDir;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('zhuoluo_consistency');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppDatabase> newDb() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    return db;
  }

  test('completeInstance 幂等：同一实例多次完成只保留一条记录', () async {
    final db = await newDb();
    addTearDown(db.close);
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: 'r',
      rrule: const Value('FREQ=DAILY'),
      createdAt: now,
    ));

    await db.completeInstance(id, today);
    await db.completeInstance(id, today);
    await db.completeInstance(id, today);

    expect(await db.isInstanceCompleted(id, today), isTrue);
    final rows = await db.allCompletionsForBackup();
    expect(rows.where((r) => r.taskId == id).length, 1,
        reason: '重复完成同一实例不应产生多行');
  });

  test('UNIQUE 约束存在：绕过幂等直接插入重复实例会抛错（防崩溃屏障）', () async {
    final db = await newDb();
    addTearDown(db.close);
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: 'r',
      rrule: const Value('FREQ=DAILY'),
      createdAt: now,
    ));

    await db.into(db.taskCompletions).insert(
      TaskCompletionsCompanion.insert(
        taskId: id,
        instanceDate: today,
        completedAt: DateTime.now(),
      ),
    );
    await expectLater(
      db.into(db.taskCompletions).insert(
        TaskCompletionsCompanion.insert(
          taskId: id,
          instanceDate: today,
          completedAt: DateTime.now(),
        ),
      ),
      throwsA(anything),
      reason: '唯一约束应阻止同实例重复插入',
    );
  });

  test('pruneCompletionsForTask：清理不再匹配新系列的旧完成记录', () async {
    final db = await newDb();
    addTearDown(db.close);
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每天重复',
      rrule: const Value('FREQ=DAILY'),
      planStart: Value(today),
      planEnd: Value(today.add(const Duration(hours: 1))),
      createdAt: now,
    ));

    // 旧系列：昨天、今天各完成一次
    await db.completeInstance(id, today.subtract(const Duration(days: 1)));
    await db.completeInstance(id, today);

    // 系列改期到 10 天后：昨天/今天的记录不匹配新系列 → 清理
    final newStart = today.add(const Duration(days: 10));
    final removed =
        await db.pruneCompletionsForTask(id, newStart, 'FREQ=DAILY');
    expect(removed.length, 2, reason: '旧日期记录应全部被清理');
    expect(await db.isInstanceCompleted(id, today), isFalse);
    expect(await db.isInstanceCompleted(id, today.subtract(const Duration(days: 1))), isFalse);

    // 新系列日期完成不受影响
    await db.completeInstance(id, newStart);
    expect(await db.isInstanceCompleted(id, newStart), isTrue);
  });

  test('长间隔重复任务（每 2 年）不误判系列结束', () async {
    final db = await newDb();
    addTearDown(db.close);
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '体检',
      rrule: const Value('FREQ=YEARLY;INTERVAL=2'),
      planStart: Value(DateTime(now.year, now.month, now.day, 9)),
      createdAt: now,
    ));
    final t = (await db.getTask(id))!;
    expect(
      await db.hasFutureInstances(t),
      isTrue,
      reason: '每 2 年任务在 370 天窗口内无实例，此前被误判系列结束',
    );
    expect(RruleService.windowDaysFor('FREQ=YEARLY;INTERVAL=2'), 733,
        reason: '窗口至少覆盖一个完整周期（2*366+1 天缓冲）');
    expect(RruleService.windowDaysFor('FREQ=DAILY'), 370);
    expect(RruleService.windowDaysFor('FREQ=WEEKLY;INTERVAL=4'), 370);
  });

  test('并发打卡同一习惯同一天不产生重复记录', () async {
    final db = await newDb();
    addTearDown(db.close);
    final habitId = await db.insertHabit('阅读', '⭐', null);
    // 模拟双击/快速连点：三个并发 toggle
    await Future.wait([
      db.checkHabit(habitId, today),
      db.checkHabit(habitId, today),
      db.checkHabit(habitId, today),
    ]);
    final rows = await db.getHabitRecords(habitId);
    expect(rows.length, lessThanOrEqualTo(1),
        reason: '并发打卡不得产生重复记录（此前 isHabitDone 崩溃）');
    // 唯一约束屏障：绕过幂等直接插入重复行应抛错
    await expectLater(
      db.insertHabitRecordFull(
        HabitRecordsCompanion(
          habitId: Value(habitId),
          date: Value(today),
          completedAt: Value(DateTime.now()),
        ),
      ),
      throwsA(anything),
      reason: 'habit_records 唯一索引应阻止同 (habit,date) 重复行',
    );
  });

  test('v2 → v3/v4 迁移：去重重复完成记录并建立唯一索引', () async {
    // 构造 v2 库（task_completions 无唯一索引、reminders 无提醒时刻列）
    // + 同一实例两条重复记录
    final file = File('${tempDir.path}/v2.sqlite');
    final raw = sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE task_completions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        instance_date INTEGER NOT NULL,
        completed_at INTEGER NOT NULL
      )
    ''');
    raw.execute('''
      CREATE TABLE reminders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        remind_minutes_before INTEGER NOT NULL DEFAULT 0,
        is_persistent INTEGER NOT NULL DEFAULT 0
      )
    ''');
    raw.execute(
      'INSERT INTO task_completions(task_id, instance_date, completed_at) '
      'VALUES (1, 100, 100), (1, 100, 200), (1, 101, 300)',
    );
    raw.execute('PRAGMA user_version = 2');
    raw.close();

    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await db.allCompletionsForBackup();
    expect(rows.length, 2, reason: '重复的 (task_id, instance_date) 应被去重');
    expect(
      rows.where((r) => r.instanceDate.millisecondsSinceEpoch == 100 * 1000)
          .length,
      1,
    );

    // v4 迁移：reminders 表应新增 remind_at_minutes 列
    final cols = await db.customSelect(
      "SELECT name FROM pragma_table_info('reminders')",
    ).get();
    expect(
      cols.map((r) => r.read<String>('name')),
      contains('remind_at_minutes'),
    );

    // 唯一索引已建立：再插重复应失败
    await expectLater(
      db.into(db.taskCompletions).insert(
        TaskCompletionsCompanion.insert(
          taskId: 1,
          instanceDate: DateTime.fromMillisecondsSinceEpoch(100 * 1000),
          completedAt: DateTime.now(),
        ),
      ),
      throwsA(anything),
    );
  });
}
