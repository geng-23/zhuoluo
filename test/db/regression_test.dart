import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_page.dart';

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
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: title,
        planStart: Value(planStart),
        rrule: Value(rrule),
        createdAt: now,
      ),
    );
  }

  group('UNTIL 边界', () {
    test('UNTIL=YYYYMMDD 时结束日当天的定时实例保留', () {
      final r = RruleService.instance;
      // 每天 09:00 开始，至 2026-08-10 结束（定时实例带时分）
      final start = DateTime(2026, 8, 1, 9, 0);
      final until = 'UNTIL=20260810';
      // 结束日当天 09:00 实例应命中（此前被解析为当日 00:00 而排除）
      expect(
        r.hitsOn('FREQ=DAILY;$until', start, DateTime(2026, 8, 10, 9, 0)),
        isTrue,
        reason: 'P1-B：UNTIL 结束日当天的实例不应被排除',
      );
      expect(
        r.hitsOn('FREQ=DAILY;$until', start, DateTime(2026, 8, 11, 9, 0)),
        isFalse,
        reason: '结束日次日不命中',
      );
      // 展开结果同样包含结束日
      final hits = r.expand(
        start,
        'FREQ=DAILY;$until',
        to: DateTime(2026, 8, 15),
      );
      expect(
        hits.any(
          (d) =>
              d.year == 2026 && d.month == 8 && d.day == 10,
        ),
        isTrue,
      );
    });

    test('UNTIL 带时分（ISO）按字面比较', () {
      final r = RruleService.instance;
      final start = DateTime(2026, 8, 1, 9, 0);
      expect(
        r.hitsOn(
          'FREQ=DAILY;UNTIL=20260810T090000',
          start,
          DateTime(2026, 8, 10, 9, 0),
        ),
        isTrue,
      );
    });
  });

  group('番茄统计窗口', () {
    test('to=月末 00:00 时当天完成的番茄记录计入', () async {
      final id = await insertTask(title: '番茄任务');
      // 月末 23:59 完成的记录（用 Raw 显式指定 completedAt，真正触达月末边界）
      final monthEnd = DateTime(now.year, now.month + 1, 0, 23, 59);
      await db.insertPomodoroRaw(
        PomodoroRecordsCompanion(
          taskId: Value(id),
          durationMinutes: Value(25),
          startedAt: Value(monthEnd.subtract(const Duration(minutes: 25))),
          completedAt: Value(monthEnd),
        ),
      );
      final records = await db.getPomodoros(
        from: DateTime(now.year, now.month, 1),
        to: DateTime(now.year, now.month + 1, 0), // 月末 00:00
      );
      expect(records, hasLength(1),
          reason: 'P1-B：to 排他 + 内部 +1 天，月末当天记录不漏计');
    });

    test('窗口外记录不计入', () async {
      final id = await insertTask(title: '番茄任务2');
      // insertPomodoro 的 completedAt 固定为 now，需用 Raw 指定窗口外完成时间
      final nextMonth = DateTime(now.year, now.month + 1, 15);
      await db.insertPomodoroRaw(
        PomodoroRecordsCompanion(
          taskId: Value(id),
          durationMinutes: Value(25),
          startedAt: Value(nextMonth),
          completedAt: Value(nextMonth),
        ),
      );
      final records = await db.getPomodoros(
        from: DateTime(now.year, now.month, 1),
        to: DateTime(now.year, now.month + 1, 0),
      );
      expect(records, isEmpty);
    });
  });

  group('例外时分渲染数据', () {
    test('例外改期到当天的实例携带 displayTime（时分）', () async {
      final start = today.subtract(const Duration(days: 30));
      final id = await insertTask(
        title: '周会',
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
        planStart: DateTime(start.year, start.month, start.day, 9),
      );
      // 改期本次：原实例（本周一）→ 改到明天 14:30
      final fromMonday = await (() async {
        final nowD = DateTime.now();
        final d = DateTime(nowD.year, nowD.month, nowD.day);
        return d.subtract(Duration(days: d.weekday - 1));
      })();
      final toDate = today.add(const Duration(days: 1));
      await db.insertException(
        TaskExceptionsCompanion.insert(
          taskId: id,
          instanceDate: fromMonday,
          action: const Value('edit'),
          overrideScheduledDate: Value(
            DateTime(toDate.year, toDate.month, toDate.day, 14, 30),
          ),
        ),
      );
      final items = await db.getCalendarItems(toDate, toDate);
      final item = items.where((i) => i.task.id == id).firstOrNull;
      expect(item, isNotNull);
      expect(item!.displayTime, isNotNull,
          reason: 'P1-B：例外改期到当天的实例应携带目标时刻');
      expect(item.displayTime!.hour, 14);
      expect(item.displayTime!.minute, 30);
    });
  });

  group('删除主路径 bump dataVersion', () {
    test('deleteTaskWithUndo 后 dataVersion 递增', () async {
      // 先建默认清单再建容器：避免控制器 init 的 ensureDefaultList 与
      // 测试内 ensureDefaultList 并发导致双插（getDefaultList 报 Too many）
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(tasksControllerProvider.notifier);
      // 等待控制器初始化完成
      var guard = 0;
      while (container.read(tasksControllerProvider).loading && guard < 200) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        guard++;
      }
      final before = container.read(dataVersionProvider);
      final id = await insertTask(title: '待删任务');
      await controller.deleteTaskWithUndo(id);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        container.read(dataVersionProvider),
        greaterThan(before),
        reason: 'P1-A：删除主路径必须 bump，跨页才能同步刷新',
      );
      expect(await db.getTask(id), isNull);
    });
  });

  group('快速添加标题提取', () {
    testWidgets('时间词整体切除，标题不再被撕裂', (tester) async {
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: QuickAddSheet())),
        ),
      );
      await tester.pumpAndSettle();

      // "每周五跑步" → 标题应为"跑步"（此前被拆成"五跑步"）
      await tester.enterText(find.byType(TextField), '每周五跑步');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      final list = await db.getDefaultList();
      final tasks = await db.getTasksByList(list.id);
      expect(tasks.single.title, '跑步',
          reason: 'P1-D：标题提取不得撕裂（每周五跑步 → 跑步）');
      expect(tasks.single.rrule, 'FREQ=WEEKLY;BYDAY=FR',
          reason: '每周五 → 周五（FR）');
    });

    testWidgets('"每时每刻"保留完整（不误删"每"）', (tester) async {
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: QuickAddSheet())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '每时每刻');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      final list = await db.getDefaultList();
      final tasks = await db.getTasksByList(list.id);
      expect(tasks.single.title, '每时每刻',
          reason: 'P1-D：普通"每"字不应被误删');
    });
  });
}
