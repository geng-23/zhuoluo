import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/trash_service.dart';
import 'package:zhuoluo/features/task/providers.dart';

import '../support/fake_notification_scheduler.dart';

/// 回收站端到端流程：删除→进回收站→恢复/彻底删除/清空/保留期清理/清单兜底
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  late AppDatabase db;
  late FakeNotificationScheduler fake;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  /// 先落库（ensureDefaultList 完成）再建容器，避免控制器 init 的
  /// ensureDefaultList 与测试的 ensureDefaultList 并发产生两个默认清单
  Future<int> insertTask({
    required String title,
    String rrule = '',
    DateTime? planStart,
    int? parentId,
    int? listId,
  }) async {
    await db.ensureDefaultList();
    final list = listId == null
        ? await db.getDefaultList()
        : (await db.getListById(listId))!;
    return db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: title,
        planStart: Value(planStart),
        rrule: Value(rrule),
        parentId: Value(parentId),
        createdAt: now,
      ),
    );
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  Future<void> addReminder(int taskId, {int minutes = 10}) async {
    await db.insertReminder(
      RemindersCompanion.insert(
        taskId: taskId,
        remindMinutesBefore: Value(minutes),
      ),
    );
    await db.updateTaskHasReminder(taskId, true);
  }

  group('删除进回收站', () {
    test('删除任务：物理删除 + 回收站落快照，撤销后回收站条目清除', () async {
      final id = await insertTask(
        title: '要删除的任务',
        planStart: DateTime(today.year, today.month, today.day, 9, 0),
      );
      await addReminder(id);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.deleteTaskWithUndo(id);
      expect(await db.getTask(id), isNull, reason: '任务物理删除');
      expect(await db.countTrash(), 1);

      final item = (await db.getTrashItems()).single;
      expect(item.originalTaskId, id);
      expect(item.title, '要删除的任务');
      final snap = decodeTrashSnapshot(item.data)!;
      expect(snap.task.title, '要删除的任务');
      expect(snap.reminders.single.taskId, id);

      // 撤销条撤销 → 任务回来 + 回收站条目删除 + 提醒行恢复 + 旧通知已取消
      await notifier.undoDelete(id);
      expect((await db.getTask(id))!.title, '要删除的任务');
      expect(await db.countTrash(), 0, reason: '撤销后不残留旧快照');
      expect((await db.getReminders(id)).length, 1, reason: '提醒行随快照恢复');
      expect(fake.cancelled, isNotEmpty, reason: '删除时通知已取消');
      await drain();
    });

    test('重复任务删除全部：系列进回收站，恢复后规则/完成记录完好', () async {
      final start = DateTime(today.year, today.month, today.day, 9, 0);
      final id = await insertTask(
        title: '每日重复',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      await db.completeInstance(id, today);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.deleteTaskWithUndo(id);
      expect(await db.getTask(id), isNull);

      final item = (await db.getTrashItems()).single;
      final snap = decodeTrashSnapshot(item.data)!;
      expect(snap.task.rrule, 'FREQ=DAILY');
      expect(snap.completions.length, 1, reason: '实例完成记录一并快照');

      await notifier.restoreFromTrash(item.id);
      final restored = (await db.getTask(id))!;
      expect(restored.rrule, 'FREQ=DAILY');
      expect(await db.isInstanceCompleted(id, today), isTrue,
          reason: '完成记录随快照恢复');
      expect(await db.countTrash(), 0);
      await drain();
    });

    test('子任务树：删父任务单条快照含整棵子树，恢复还原全树', () async {
      final parent = await insertTask(title: '父任务');
      final child1 = await insertTask(title: '子1', parentId: parent);
      final child2 = await insertTask(title: '子2', parentId: parent);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.deleteTaskWithUndo(parent);
      expect(await db.getTask(parent), isNull);
      expect(await db.getTask(child1), isNull);
      expect(await db.getTask(child2), isNull);
      expect(await db.countTrash(), 1, reason: '整棵树一条快照');

      final item = (await db.getTrashItems()).single;
      final snap = decodeTrashSnapshot(item.data)!;
      expect(snap.subTasks.length, 2);

      await notifier.restoreFromTrash(item.id);
      expect((await db.getTask(child1))!.parentId, parent);
      expect((await db.getTask(child2))!.parentId, parent);
      await drain();
    });
  });

  group('批量与父链', () {
    test('乱序批量删除 [子,父]：两条快照，恢复后全树回来', () async {
      final parent = await insertTask(title: '父');
      final child = await insertTask(title: '子', parentId: parent);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.batchDelete([child, parent]);
      expect(await db.countTrash(), 2);

      final rows = await db.getTrashItems();
      await notifier.batchRestoreFromTrash(rows.map((r) => r.id).toList());
      expect((await db.getTask(parent))!.title, '父');
      expect((await db.getTask(child))!.parentId, parent);
      expect(await db.countTrash(), 0);
      await drain();
    });

    test('单独恢复子任务：先自动恢复其仍在回收站中的父任务（防外键崩溃）', () async {
      final parent = await insertTask(title: '父');
      final child = await insertTask(title: '子', parentId: parent);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.batchDelete([child, parent]);

      final childRow = (await db.getTrashItems())
          .firstWhere((r) => r.originalTaskId == child);
      await notifier.restoreFromTrash(childRow.id);
      expect((await db.getTask(parent))!.title, '父', reason: '父链自动先恢复');
      expect((await db.getTask(child))!.parentId, parent);
      expect(await db.countTrash(), 0, reason: '父+子两条快照都被消费');
      await drain();
    });
  });

  group('彻底删除与清理', () {
    test('彻底删除单条：任务保持删除且回收站条目消失', () async {
      final id = await insertTask(title: '彻底删我');
      final notifier = makeContainer().read(tasksControllerProvider.notifier);
      await notifier.deleteTaskWithUndo(id);

      final item = (await db.getTrashItems()).single;
      await notifier.purgeTrashItem(item.id);
      expect(await db.getTask(id), isNull);
      expect(await db.countTrash(), 0);
    });

    test('清空回收站：全部条目消失', () async {
      final idA = await insertTask(title: 'A');
      final idB = await insertTask(title: 'B');
      final notifier = makeContainer().read(tasksControllerProvider.notifier);
      await notifier.deleteTaskWithUndo(idA);
      await notifier.deleteTaskWithUndo(idB);
      expect(await db.countTrash(), 2);

      await notifier.clearTrash();
      expect(await db.countTrash(), 0);
      await drain();
    });

    test('保留期清理：仅删超期条目', () async {
      // 超期条目（30 天前）与未超期条目（当前）
      await db.ensureDefaultList();
      await db.insertTrashItem(
        TrashItemsCompanion.insert(
          originalTaskId: 9001,
          title: '超期快照',
          listName: '收件箱',
          deletedAt: DateTime.now().subtract(const Duration(days: 30)),
          data: '{}',
        ),
      );
      final id = await insertTask(title: '刚删除');
      final notifier = makeContainer().read(tasksControllerProvider.notifier);
      await notifier.deleteTaskWithUndo(id);

      await notifier.purgeExpiredTrash(DateTime.now());
      final remain = await db.getTrashItems();
      expect(remain.length, 1, reason: '仅超期条目被清理');
      expect(remain.single.title, '刚删除');
      await drain();
    });
  });

  group('清单兜底', () {
    test('清单已删除时恢复回收站任务：回落到默认清单', () async {
      await db.ensureDefaultList();
      final listId = await db.insertList('临时清单', '#4F8EF7', 1);
      final id = await insertTask(title: '清单里的任务', listId: listId);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.deleteTaskWithUndo(id);
      await db.deleteList(listId, deleteTasks: false);

      final item = (await db.getTrashItems()).single;
      await notifier.restoreFromTrash(item.id);
      final restored = (await db.getTask(id))!;
      expect(restored.listId, (await db.getDefaultList()).id,
          reason: '原清单已删除，恢复回落到默认清单');
      await drain();
    });

    test('清单连带删除任务：任务进回收站可恢复', () async {
      final listId = await db.insertList('待删清单', '#E53935', 1);
      final id = await insertTask(title: '连带任务', listId: listId);
      final notifier = makeContainer().read(tasksControllerProvider.notifier);

      await notifier.deleteList(listId, deleteTasks: true);
      expect(await db.getListById(listId), isNull, reason: '清单已删');
      expect(await db.getTask(id), isNull, reason: '任务物理删除');
      expect(await db.countTrash(), 1, reason: '连带删除的任务进回收站');

      final item = (await db.getTrashItems()).single;
      await notifier.restoreFromTrash(item.id);
      expect((await db.getTask(id))!.title, '连带任务');
      await drain();
    });
  });
}
