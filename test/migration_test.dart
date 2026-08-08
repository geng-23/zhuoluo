import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zhuoluo/data/database/database.dart';

/// v0.2 数据迁移测试：v1 schema（旧列，unix 秒存储）→ v2（plan_start/plan_end/due_time）
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('zhuoluo_migrate_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// 手动创建 v1 数据库（旧表结构 + 数据 + user_version=1）
  /// drift 的 dateTime 列以 unix 秒（int）存储
  File createV1Db() {
    final file = File('${tempDir.path}/test_v1.sqlite');
    final db = sqlite3.open(file.path);
    db.execute('''
      CREATE TABLE lists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        color TEXT NOT NULL DEFAULT '#4F8EF7',
        sort_order INTEGER NOT NULL DEFAULT 0,
        show_in_calendar INTEGER NOT NULL DEFAULT 1,
        is_default INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        list_id INTEGER NOT NULL,
        parent_id INTEGER,
        title TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        quadrant INTEGER NOT NULL DEFAULT 4,
        scheduled_date INTEGER,
        due_date INTEGER,
        is_all_day INTEGER NOT NULL DEFAULT 0,
        start_time INTEGER,
        duration_minutes INTEGER NOT NULL DEFAULT 60,
        rrule TEXT NOT NULL DEFAULT '',
        has_reminder INTEGER NOT NULL DEFAULT 0,
        has_note INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        skipped_dates TEXT NOT NULL DEFAULT '[]',
        completed_at INTEGER,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE reminders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        remind_minutes_before INTEGER NOT NULL DEFAULT 0,
        is_persistent INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE task_completions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        instance_date INTEGER NOT NULL,
        completed_at INTEGER NOT NULL
      );
      CREATE TABLE task_exceptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        instance_date INTEGER NOT NULL,
        action TEXT NOT NULL DEFAULT 'edit',
        override_scheduled_date INTEGER
      );
      CREATE TABLE habits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        icon TEXT NOT NULL DEFAULT '⭐',
        frequency TEXT NOT NULL DEFAULT 'daily',
        reminder_time INTEGER,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE habit_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        habit_id INTEGER NOT NULL,
        date INTEGER NOT NULL,
        completed_at INTEGER NOT NULL
      );
      CREATE TABLE pomodoro_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER,
        duration_minutes INTEGER NOT NULL,
        started_at INTEGER NOT NULL,
        completed_at INTEGER NOT NULL
      );
      CREATE TABLE settings (
        key TEXT NOT NULL PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    db.execute('PRAGMA user_version = 1');
    int unix(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    // 测试数据：定时任务、全天任务、有 due_date 任务
    db.execute('''INSERT INTO lists (id, name, color, sort_order, show_in_calendar, is_default, created_at)
      VALUES (1, '收件箱', '#4F8EF7', 0, 1, 1, ${unix(DateTime(2026, 8, 1))})''');
    db.execute('''INSERT INTO tasks (id, list_id, title, scheduled_date, due_date, is_all_day, start_time, duration_minutes, created_at)
      VALUES
      (1, 1, '定时任务', ${unix(DateTime(2026, 8, 10))}, NULL, 0, ${unix(DateTime(2026, 8, 10, 14, 30))}, 90, ${unix(DateTime(2026, 8, 1))}),
      (2, 1, '全天任务', ${unix(DateTime(2026, 8, 11))}, NULL, 1, NULL, 60, ${unix(DateTime(2026, 8, 1))}),
      (3, 1, '有截止', NULL, ${unix(DateTime(2026, 8, 15))}, 0, NULL, 60, ${unix(DateTime(2026, 8, 1))})''');
    db.dispose();
    return file;
  }

  test('v1 → v2 迁移：计划时间/截止时间转换正确', () async {
    final file = createV1Db();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    // 迁移后验证
    final tasks = await db.allTasksForBackup();
    expect(tasks.length, 3);

    // 定时任务：plan_start=2026-08-10 14:30, plan_end=+90min=16:00
    final t1 = tasks.firstWhere((t) => t.id == 1);
    expect(t1.planStart, DateTime(2026, 8, 10, 14, 30));
    expect(t1.planEnd, DateTime(2026, 8, 10, 16, 0));
    expect(t1.isAllDay, false);

    // 全天任务：plan_start=当天 00:00, plan_end=+60min
    final t2 = tasks.firstWhere((t) => t.id == 2);
    expect(t2.planStart, DateTime(2026, 8, 11));
    expect(t2.planEnd, DateTime(2026, 8, 11, 1, 0));
    expect(t2.isAllDay, true);

    // 有截止无计划：due_time 转换
    final t3 = tasks.firstWhere((t) => t.id == 3);
    expect(t3.dueTime, DateTime(2026, 8, 15));
    expect(t3.planStart, isNull);

    // 新列 color 默认空
    expect(t1.color, '');
  });

  test('迁移后新任务可正常创建与查询', () async {
    final file = createV1Db();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    final id = await db.insertTask(TasksCompanion.insert(
      listId: 1,
      title: '新任务',
      planStart: Value(DateTime(2026, 8, 20, 9, 30)),
      planEnd: Value(DateTime(2026, 8, 20, 10, 0)),
      createdAt: DateTime.now(),
    ));
    final t = await db.getTask(id);
    expect(t!.planStart, DateTime(2026, 8, 20, 9, 30));
    expect(t.planEnd, DateTime(2026, 8, 20, 10, 0));
  });
}
