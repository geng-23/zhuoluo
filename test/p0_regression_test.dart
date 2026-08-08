import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// P0 回归测试（docs/00-code-audit-and-correctness-plan.md 第 3 章）
///
/// 覆盖：
/// - 3.1 重复任务完成记录时间精度（实例日期归一化）
/// - 3.3 单次改期撤销（删除原例外，而非新增反向例外）
/// - 3.4 删除任务树完整处理关联数据（番茄记录/子任务提醒/事务）
/// - 3.5 撤销删除恢复全天提醒时刻
/// - 3.6 备份恢复原子性（失败回滚不丢原数据）
/// - 3.8 修改/清除重复规则统一收口清理
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    String rrule = '',
    DateTime? planStart,
    bool isAllDay = false,
    int? parentId,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: title,
        planStart: Value(planStart),
        isAllDay: Value(isAllDay),
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

  /// 等待任务控制器初始化完成（构造函数异步 init）
  Future<void> settle(ProviderContainer container) async {
    final state = container.read(tasksControllerProvider);
    var guard = 0;
    while (state.loading && guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
  }

  /// 控制器写操作会 fire-and-forget 触发 dataVersion 监听刷新，
  /// 需等其完成再结束测试（否则 tearDown 关闭 db 后仍在使用）
  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  group('P0-3.1 实例日期归一化', () {
    test('计划时间 09:00 的重复任务：完成记录 00:00 与实例 09:00 互相识别', () async {
      final start = DateTime(today.year, today.month, today.day, 9, 0);
      final id = await insertTask(
        title: '每日 9 点任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      // 普通完成流程存 00:00
      await db.completeInstance(id, today);
      // 提醒调度用 RRULE 展开的实例（09:00）判断是否完成 → 必须识别为已完成
      expect(
        await db.isInstanceCompleted(
          id,
          DateTime(today.year, today.month, today.day, 9, 0),
        ),
        isTrue,
        reason: '带时分的实例日期应命中 00:00 的完成记录（P0-3.1）',
      );
      // 存储的记录本身归一化为 00:00（不产生第二条同实例不同时刻的记录）
      final rows = await (db.select(
        db.taskCompletions,
      )..where((c) => c.taskId.equals(id))).get();
      expect(rows.length, 1);
      expect(rows.single.instanceDate, today);
    });

    test('调度器展开实例（带时分）可正确过滤已完成实例', () async {
      final start = DateTime(today.year, today.month, today.day, 9, 0);
      final id = await insertTask(
        title: '每日 9 点任务 2',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      await db.completeInstance(id, today);
      final instances = RruleService.instance.expand(
        start,
        'FREQ=DAILY',
        from: today.subtract(const Duration(days: 1)),
        to: today.add(const Duration(days: 3)),
      );
      final pending = <DateTime>[];
      for (final inst in instances) {
        // 模拟调度器过滤逻辑：已完成的实例不应再排提醒
        if (!await db.isInstanceCompleted(id, inst)) {
          pending.add(inst);
        }
      }
      expect(
        pending.any(
          (d) =>
              d.year == today.year &&
              d.month == today.month &&
              d.day == today.day,
        ),
        isFalse,
        reason: '今天已完成，今天 09:00 的实例不应再进入排期',
      );
      // 展开窗口 [today, today+3]：共 3 个实例（today/+1/+2，+3 超出窗口），
      // 今天已完成 → 剩余 2 个进入排期
      expect(pending.length, 2, reason: '其余实例正常保留');
    });

    test('异常实例日期写入时归一化（例外/跳过基准一致）', () async {
      final id = await insertTask(
        title: '每日任务 3',
        rrule: 'FREQ=DAILY',
        planStart: DateTime(today.year, today.month, today.day, 8, 30),
      );
      final exId = await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: DateTime(
            today.year,
            today.month,
            today.day,
            8,
            30, // 带时分写入
          ),
          action: const Value('edit'),
          overrideScheduledDate: Value(today.add(const Duration(days: 2))),
        ),
      );
      expect(exId, greaterThan(0));
      final exs = await db.getExceptions(id);
      expect(exs.single.instanceDate, today, reason: '例外实例日期归一化为 00:00');
    });
  });

  group('P0-3.3 例外改期撤销', () {
    test('撤销改期删除原例外，不新增反向例外', () async {
      final id = await insertTask(
        title: '周会',
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
        planStart: DateTime(today.year, today.month, today.day, 10),
      );
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      final toDate = today.add(const Duration(days: 2));

      final exId = await notifier.editException(id, today, toDate);
      expect(exId, greaterThan(0), reason: '返回例外记录 ID');
      expect((await db.getExceptions(id)).length, 1);

      // 撤销：删除该例外 → 回到原状态（原日期恢复实例）
      await notifier.undoEditException(id, exId);
      await drain();
      expect(
        await db.getExceptions(id),
        isEmpty,
        reason: '撤销后不应残留 A→B 与 B→A 两条冲突例外',
      );
    });
  });

  group('P0-3.4 删除任务树完整处理', () {
    test('删除父任务连子树：子任务提醒/番茄记录/完成记录/例外全部清理，无外键错误', () async {
      final parentId = await insertTask(title: '父任务');
      final childId = await insertTask(
        title: '子任务',
        parentId: parentId,
        planStart: DateTime(today.year, today.month, today.day, 9),
      );
      await db.insertReminder(
        RemindersCompanion.insert(
          taskId: childId,
          remindMinutesBefore: const Value(10),
        ),
      );
      // 父任务关联番茄记录（外键引用 Tasks）
      await db.insertPomodoro(parentId, 25, now);
      // 父任务关联完成记录 + 例外
      await db.completeInstance(parentId, today);
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: parentId,
          instanceDate: today.add(const Duration(days: 1)),
          action: const Value('delete'),
        ),
      );

      await db.deleteTask(parentId);

      expect(await db.getTask(parentId), isNull);
      expect(await db.getTask(childId), isNull);
      expect(await db.getReminders(childId), isEmpty);
      expect(
        await (db.select(
          db.pomodoroRecords,
        )..where((p) => p.taskId.equals(parentId)))
            .get(),
        isEmpty,
        reason: '删除任务时关联番茄记录一并清理（避免外键错误）',
      );
      expect(
        await (db.select(
          db.taskCompletions,
        )..where((c) => c.taskId.equals(parentId)))
            .get(),
        isEmpty,
      );
      expect(await db.getExceptions(parentId), isEmpty);
    });
  });

  group('P0-3.5 撤销删除恢复完整提醒字段', () {
    test('全天任务提醒时刻 remindAtMinutes 在删除撤销后保留', () async {
      final container = makeContainer();
      await settle(container);
      final notifier = container.read(tasksControllerProvider.notifier);
      final parentId = await insertTask(
        title: '全天任务',
        isAllDay: true,
        planStart: today,
      );
      await db.insertReminder(
        RemindersCompanion.insert(
          taskId: parentId,
          remindMinutesBefore: const Value(0),
          remindAtMinutes: const Value(1260), // 21:00
        ),
      );
      final childId = await insertTask(
        title: '子任务',
        parentId: parentId,
        isAllDay: true,
        planStart: today,
      );
      await db.insertReminder(
        RemindersCompanion.insert(
          taskId: childId,
          remindMinutesBefore: const Value(15),
          remindAtMinutes: const Value(600), // 10:00
        ),
      );
      await db.insertPomodoro(parentId, 25, now);

      await notifier.deleteTaskWithUndo(parentId);
      expect(await db.getTask(parentId), isNull);
      expect(await db.getTask(childId), isNull);

      await notifier.undoDelete(parentId);
      await drain();

      expect(await db.getTask(parentId), isNotNull);
      expect(await db.getTask(childId), isNotNull, reason: '子任务一并恢复');
      final restoredParent = await db.getReminders(parentId);
      final restoredChild = await db.getReminders(childId);
      expect(restoredParent.single.remindAtMinutes, 1260,
          reason: 'P0-3.5：撤销删除后全天提醒时刻必须保留');
      expect(restoredChild.single.remindAtMinutes, 600,
          reason: '子任务提醒时刻同样恢复');
      expect(restoredParent.single.remindMinutesBefore, 0);
      expect(
        await (db.select(
          db.pomodoroRecords,
        )..where((p) => p.taskId.equals(parentId)))
            .get(),
        hasLength(1),
        reason: 'P0-3.4：关联番茄记录随撤销恢复',
      );
    });
  });

  group('P0-3.6 备份恢复原子性', () {
    Future<String> validBackupJson() async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '备份任务',
          createdAt: now,
        ),
      );
      return BackupService(db).exportJson();
    }

    Map<String, dynamic> emptyData() => {
      'version': 1,
      'lists': <dynamic>[],
      'tasks': <dynamic>[],
      'reminders': <dynamic>[],
      'completions': <dynamic>[],
      'exceptions': <dynamic>[],
      'habits': <dynamic>[],
      'habitRecords': <dynamic>[],
      'pomodoros': <dynamic>[],
      'settings': <dynamic>[],
    };

    test('解析失败（字段缺失）：抛异常且原数据完整保留', () async {
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      await db2.ensureDefaultList();
      final list = await db2.getDefaultList();
      await db2.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '原数据',
          createdAt: now,
        ),
      );

      final bad = emptyData();
      bad['tasks'] = [
        {
          'id': 1,
          'listId': list.id,
          'title': '缺字段任务',
          'planStart': null,
          'planEnd': null,
          'dueTime': null,
          // 缺少 note/quadrant/isAllDay/createdAt 等必填字段
        },
      ];
      await expectLater(
        BackupService(db2).importJson(jsonEncode(bad)),
        throwsA(anything),
        reason: '字段缺失应在写入前抛出',
      );
      final tasks = await db2.getAllUncompleted();
      expect(tasks.map((t) => t.title), contains('原数据'),
          reason: 'P0-3.6：恢复失败不得清空原数据');
    });

    test('外键违反（listId 不存在）：事务回滚，原数据完整保留', () async {
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      await db2.ensureDefaultList();
      final list = await db2.getDefaultList();
      await db2.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '原数据',
          createdAt: now,
        ),
      );

      final bad = emptyData();
      bad['tasks'] = [
        {
          'id': 1,
          'listId': 9999, // 不存在的清单 → 外键错误
          'parentId': null,
          'title': '孤立任务',
          'note': '',
          'quadrant': 4,
          'planStart': null,
          'planEnd': null,
          'dueTime': null,
          'isAllDay': false,
          'color': '',
          'rrule': '',
          'hasReminder': false,
          'hasNote': false,
          'sortOrder': 0,
          'skippedDates': '[]',
          'completedAt': null,
          'createdAt': now.toIso8601String(),
        },
      ];
      await expectLater(
        BackupService(db2).importJson(jsonEncode(bad)),
        throwsA(anything),
        reason: '外键失败应触发回滚',
      );
      final tasks = await db2.getAllUncompleted();
      expect(tasks.map((t) => t.title), contains('原数据'),
          reason: 'P0-3.6：外键失败回滚后原数据完整保留');
      expect(await db2.getDefaultList(), isNotNull);
    });

    test('合法备份仍可正常恢复（回归不破坏主流程）', () async {
      final json = await validBackupJson();
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      final count = await BackupService(db2).importJson(json);
      expect(count, 1);
      final tasks = await db2.getAllUncompleted();
      expect(tasks.single.title, '备份任务');
    });
  });

  group('P0-3.8 重复规则收口清理', () {
    test('清除重复规则：删除全部实例完成记录与例外', () async {
      final start = today.subtract(const Duration(days: 10));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      await db.completeInstance(id, today.subtract(const Duration(days: 2)));
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: today.subtract(const Duration(days: 1)),
          action: const Value('delete'),
        ),
      );
      await db.applyRecurringChange(
        id,
        oldRrule: 'FREQ=DAILY',
        newRrule: '',
      );
      expect(
        await (db.select(
          db.taskCompletions,
        )..where((c) => c.taskId.equals(id)))
            .get(),
        isEmpty,
        reason: '清除重复后实例完成记录不应残留（避免参与统计）',
      );
      expect(await db.getExceptions(id), isEmpty,
          reason: '清除重复后例外不应残留（避免影响展开）');
    });

    test('更换规则：清理不再命中新规则的完成记录，保留仍命中的', () async {
      final start = today.subtract(const Duration(days: 10));
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: start,
      );
      // 偶数偏移日命中 INTERVAL=2，奇数偏移日不命中
      await db.completeInstance(id, start); // 偏移 0 → 保留
      await db.completeInstance(
        id,
        start.add(const Duration(days: 1)), // 偏移 1 → 清理
      );
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: start.add(const Duration(days: 1)), // 不再命中 → 清理
          action: const Value('edit'),
          overrideScheduledDate: Value(start.add(const Duration(days: 5))),
        ),
      );
      final removed = await db.applyRecurringChange(
        id,
        oldRrule: 'FREQ=DAILY',
        newRrule: 'FREQ=DAILY;INTERVAL=2',
        newStart: start,
      );
      expect(removed.map((c) => c.instanceDate), contains(start.add(const Duration(days: 1))));
      expect(
        await db.isInstanceCompleted(
          id,
          start.add(const Duration(days: 1)),
        ),
        isFalse,
        reason: 'P0-3.8：不再命中新规则的完成记录被清理',
      );
      expect(await db.isInstanceCompleted(id, start), isTrue,
          reason: '仍命中新规则的过去实例保留');
      expect(await db.getExceptions(id), isEmpty,
          reason: '例外实例日不再命中新规则时一并清理');
    });
  });

  group('P0-1 批量完成撤销语义', () {
    test('batchComplete 返回实际执行集合：跳过今日已完成的重复任务与已完成任务', () async {
      final container = makeContainer();
      await settle(container);
      // 重复任务 A：今日已完成 → 应被跳过（不得被撤销条误反转）
      final a = await insertTask(title: '每日任务', rrule: 'FREQ=DAILY');
      await db.completeInstance(a, today);
      // 普通任务 B：未完成 → 应被执行
      final b = await insertTask(title: '普通任务');
      // 普通任务 C：已完成 → 应被跳过（切换语义会误撤销）
      final c = await insertTask(title: '已完成任务');
      await db.completeTask(c);

      final notifier = container.read(tasksControllerProvider.notifier);
      final acted = await notifier.batchComplete([a, b, c]);

      expect(acted, [b], reason: '撤销条必须按实际执行集合回滚');
      expect(await db.isInstanceCompleted(a, today), isTrue,
          reason: '今日已完成的重复任务不得被批量完成撤销');
      expect((await db.getTask(b))!.completedAt, isNotNull,
          reason: '普通任务 B 应已完成');
      expect((await db.getTask(c))!.completedAt, isNotNull,
          reason: '已完成的 C 不得被切换语义反转成未完成');
      await drain();
    });
  });

  group('P0-2 跳过/撤销跳过保留完成记录', () {
    test('跳过本次删除完成记录，撤销跳过恢复（含原完成时间）', () async {
      final container = makeContainer();
      await settle(container);
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: DateTime(today.year, today.month, today.day, 9),
      );
      await db.completeInstance(id, today);
      final comp = await db.getInstanceCompletion(id, today);
      expect(comp, isNotNull, reason: '前置：完成记录存在');

      final notifier = container.read(tasksControllerProvider.notifier);
      await notifier.skipInstance(id, today);
      expect(await db.getInstanceCompletion(id, today), isNull,
          reason: '跳过本次应删除当天完成记录（C1-1 语义不变）');

      await notifier.unskipInstance(id, today);
      final restored = await db.getInstanceCompletion(id, today);
      expect(restored, isNotNull, reason: '撤销跳过应恢复完成记录（P0-2）');
      expect(restored!.completedAt, comp!.completedAt,
          reason: '恢复的记录应保留原完成时间，统计不漂移');
      await drain();
    });
  });

  group('P1-12 skippedDates 非法 JSON 防护', () {
    test('database 层：非法 skippedDates 下 expandTaskForDate 不抛异常', () async {
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: DateTime(today.year, today.month, today.day, 9),
      );
      await db.updateTask(
        id,
        TasksCompanion(skippedDates: const Value('{bad json')),
      );
      final t = (await db.getTask(id))!;
      final result = await db.expandTaskForDate(t, today);
      expect(result, isNotEmpty,
          reason: '非法 skippedDates 视为无跳过，规则日应正常命中实例');
    });

    test('控制器层：非法 skippedDates 下跳过/撤销不抛异常', () async {
      final container = makeContainer();
      await settle(container);
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: DateTime(today.year, today.month, today.day, 9),
      );
      await db.updateTask(
        id,
        TasksCompanion(skippedDates: const Value('{bad json')),
      );
      final notifier = container.read(tasksControllerProvider.notifier);
      await notifier.skipInstance(id, today);
      await notifier.unskipInstance(id, today);
      final t = (await db.getTask(id))!;
      expect(t.skippedDates, isNot('{bad json'),
          reason: '操作后应写出合法 JSON');
      await drain();
    });
  });
}
