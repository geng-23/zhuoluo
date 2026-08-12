import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/trash_service.dart';

/// 回收站表 CRUD / 超期清理 / 备份恢复清空 / v5→v6 迁移
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> addTrash(
    int originalTaskId,
    String title,
    DateTime deletedAt,
  ) =>
      db.insertTrashItem(
        TrashItemsCompanion.insert(
          originalTaskId: originalTaskId,
          title: title,
          listName: '收件箱',
          deletedAt: deletedAt,
          data: '{}',
        ),
      );

  group('回收站 CRUD', () {
    test('插入/倒序列表/单查/按原任务 id 查', () async {
      await addTrash(1, '任务A', DateTime(2026, 8, 1));
      await addTrash(2, '任务B', DateTime(2026, 8, 10));
      await addTrash(3, '任务C', DateTime(2026, 8, 5));

      final items = await db.getTrashItems();
      expect(items.map((i) => i.title).toList(), ['任务B', '任务C', '任务A'],
          reason: '按删除时间倒序');

      final single = await db.getTrashItem(items[1].id);
      expect(single!.originalTaskId, 3);

      final byId = await db.getTrashItemByOriginalTaskId(2);
      expect(byId!.title, '任务B');
      expect(await db.getTrashItemByOriginalTaskId(99), isNull);
    });

    test('删除单条/按原任务 id 删除/清空/计数', () async {
      await addTrash(1, 'A', DateTime(2026, 8, 1));
      await addTrash(2, 'B', DateTime(2026, 8, 2));
      await addTrash(3, 'C', DateTime(2026, 8, 3));
      expect(await db.countTrash(), 3);

      final a = await db.getTrashItemByOriginalTaskId(1);
      await db.deleteTrashItem(a!.id);
      expect(await db.countTrash(), 2);

      await db.deleteTrashItemByOriginalTaskId(2);
      expect(await db.countTrash(), 1);

      await db.clearTrash();
      expect(await db.countTrash(), 0);
    });

    test('超期清理：只删早于 cutoff 的条目', () async {
      await addTrash(1, '过期', DateTime(2026, 8, 1));
      await addTrash(2, '未过期', DateTime(2026, 8, 28));
      await db.deleteTrashOlderThan(DateTime(2026, 8, 15));

      final remain = await db.getTrashItems();
      expect(remain.length, 1);
      expect(remain.single.originalTaskId, 2);
    });
  });

  group('备份恢复清空回收站', () {
    test('replaceAll 后回收站条目被清空', () async {
      await addTrash(1, 'A', DateTime(2026, 8, 1));
      await db.replaceAll(
        listRows: [],
        taskRows: [],
        reminderRows: [],
        completionRows: [],
        exceptionRows: [],
        habitRows: [],
        habitRecordRows: [],
        pomodoroRows: [],
        settingRows: [],
      );
      expect(await db.countTrash(), 0,
          reason: '备份恢复必须清空回收站，避免旧快照复活');
    });
  });

  group('快照编解码', () {
    test('TrashSnapshot 往返无损', () async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final id = await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '根任务',
          createdAt: DateTime(2026, 8, 1),
        ),
      );
      final root = (await db.getTask(id))!;
      final snap = TrashSnapshot(
        task: root,
        subTasks: [root.copyWith(id: id + 1, title: '子任务')],
        reminders: [
          Reminder(
            id: 1,
            taskId: id,
            remindMinutesBefore: 10,
            isPersistent: false,
            remindAtMinutes: null,
          ),
        ],
      );
      final decoded = decodeTrashSnapshot(encodeTrashSnapshot(snap))!;
      expect(decoded.task.title, '根任务');
      expect(decoded.task.id, id);
      expect(decoded.subTasks.single.title, '子任务');
      expect(decoded.reminders.single.remindMinutesBefore, 10);
    });

    test('损坏 JSON 返回 null 不抛异常', () {
      expect(decodeTrashSnapshot('not-json'), isNull);
      expect(decodeTrashSnapshot('{"version":1}'), isNull);
    });
  });

  group('v5 → v6 迁移', () {
    test('v5 库打开后自动建回收站表，存量数据不受影响', () async {
      final tempDir = Directory.systemTemp.createTempSync('zhuoluo_v5_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final file = File('${tempDir.path}/v5.sqlite');
      final raw = sqlite3.open(file.path);
      // v5 schema（9 张表，无 trash_items），user_version=5
      raw.execute('''
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
          plan_start INTEGER,
          plan_end INTEGER,
          due_time INTEGER,
          is_all_day INTEGER NOT NULL DEFAULT 0,
          rrule TEXT NOT NULL DEFAULT '',
          color TEXT NOT NULL DEFAULT '',
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
          is_persistent INTEGER NOT NULL DEFAULT 0,
          remind_at_minutes INTEGER
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
      raw.execute('PRAGMA user_version = 5');
      int unix(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
      raw.execute(
        '''INSERT INTO lists (id, name, color, sort_order, show_in_calendar, is_default, created_at)
          VALUES (1, '收件箱', '#4F8EF7', 0, 1, 1, ${unix(DateTime(2026, 8, 1))})''',
      );
      raw.execute(
        '''INSERT INTO tasks (id, list_id, title, created_at)
          VALUES (1, 1, '存量任务', ${unix(DateTime(2026, 8, 1))})''',
      );
      raw.close();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // 存量数据完好
      final t = await migrated.getTask(1);
      expect(t!.title, '存量任务');

      // 回收站表可用（已建）
      await migrated.insertTrashItem(
        TrashItemsCompanion.insert(
          originalTaskId: 1,
          title: '存量任务的快照',
          listName: '收件箱',
          deletedAt: DateTime(2026, 8, 2),
          data: '{}',
        ),
      );
      final items = await migrated.getTrashItems();
      expect(items.single.originalTaskId, 1);
    });
  });
}
