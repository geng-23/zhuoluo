import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';
import 'package:zhuoluo/features/task/providers.dart';

import 'support/fake_notification_scheduler.dart';

/// 反直觉修复回归测试（23 项修复中的关键行为）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    // 调度路径注入替身：跳过实例等操作内部会重排提醒，避免触发
    // 平台插件未初始化异常（此前依赖异常吞掉，属假绿）
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    String rrule = '',
    DateTime? planStart,
    DateTime? planEnd,
    bool isAllDay = false,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: title,
        planStart: Value(planStart),
        planEnd: Value(planEnd),
        isAllDay: Value(isAllDay),
        rrule: Value(rrule),
        createdAt: now,
      ),
    );
  }

  Future<ProviderContainer> makeContainer() async {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    // 等待控制器初始化
    var guard = 0;
    while (container.read(tasksControllerProvider).loading && guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
    return container;
  }

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  group('C1-1 跳过本次清理当天完成记录', () {
    test('跳过已完成的实例后，完成状态与已完成视图同步清除', () async {
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: today,
      );
      await db.completeInstance(id, today);
      expect(await db.isInstanceCompleted(id, today), isTrue);

      final container = await makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      await notifier.skipInstance(id, today);
      await drain();

      expect(await db.isInstanceCompleted(id, today), isFalse,
          reason: 'C1-1：跳过实例后当天完成记录应清理');
      final done = await db.getCompletedTasks();
      expect(done.map((t) => t.id), isNot(contains(id)),
          reason: 'C1-1：已完成视图不再收录被跳过的实例');
    });
  });

  group('C8-2 批量完成跳过已完成的重复任务', () {
    test('今天已完成的重复任务不会被"批量完成"反转为撤销', () async {
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: today,
      );
      await db.completeInstance(id, today);

      final container = await makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      await notifier.batchComplete([id]);
      await drain();

      expect(await db.isInstanceCompleted(id, today), isTrue,
          reason: 'C8-2：批量完成不得把已完成实例反转为未完成');
    });
  });

  group('C8-7 清单视图过滤已完成', () {
    test('已完成任务在清单视图中不再显示', () async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final doneId = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '已完成任务',
        createdAt: now,
      ));
      final pendingId = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '进行中任务',
        createdAt: now,
      ));
      await db.completeTask(doneId);

      final container = await makeContainer();
      final notifier = container.read(tasksControllerProvider.notifier);
      notifier.selectList(list.id);
      await drain();
      final visible = container
          .read(tasksControllerProvider)
          .tasks
          .map((t) => t.id)
          .toList();
      expect(visible, contains(pendingId));
      expect(visible, isNot(contains(doneId)),
          reason: 'C8-7：清单视图与"全部"一致，已完成任务不再留存');
    });
  });

  group('C3-1 日历快加重复+无时间 → 全天', () {
    testWidgets('输入"每天阅读"创建全天重复任务（不再 00:00-00:00 定时）', (tester) async {
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: QuickAddSheetWithDefaults(DateTime.now()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '每天阅读');
      await tester.tap(find.text('添加'));
      // 注意：testWidgets 在 FakeAsync 中运行，Future.delayed 不会自动推进，
      // 必须用 pump(duration) 推进虚拟时钟让 addTask 异步链完成
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final list = await db.getDefaultList();
      final tasks = await db.getTasksByList(list.id);
      expect(tasks.single.title, '每天阅读');
      expect(tasks.single.rrule, 'FREQ=DAILY');
      expect(tasks.single.isAllDay, isTrue,
          reason: 'C3-1：重复+无明确时间应为全天任务');
      expect(
        tasks.single.planStart!.hour == 0 && tasks.single.planStart!.minute == 0,
        isTrue,
      );
    });
  });

  group('C5-1 拖拽落点 23:00 跨天回退', () {
    test('1 小时任务拖到 23:00 → 回退到 22:00（不再变跨天）', () async {
      final id = await insertTask(
        title: '一小时任务',
        planStart: DateTime(today.year, today.month, today.day, 10),
        planEnd: DateTime(today.year, today.month, today.day, 11),
      );
      final container = await makeContainer();
      final notifier = container.read(calendarControllerProvider.notifier);
      await notifier.moveTaskToDateTime(
        id,
        DateTime(today.year, today.month, today.day, 23, 0),
      );
      await drain();

      final t = (await db.getTask(id))!;
      expect(t.planStart!.hour, 22,
          reason: 'C5-1：落点 23:00 时长 1h → 回退起点 22:00');
      expect(t.planEnd!.hour, 23);
      expect(
        t.planStart!.year == t.planEnd!.year &&
            t.planStart!.month == t.planEnd!.month &&
            t.planStart!.day == t.planEnd!.day,
        isTrue,
        reason: 'C5-1：不得生成跨天任务跳进置顶区',
      );
    });

    test('15:00 正常拖拽不受影响', () async {
      final id = await insertTask(
        title: '两小时任务',
        planStart: DateTime(today.year, today.month, today.day, 10),
        planEnd: DateTime(today.year, today.month, today.day, 12),
      );
      final container = await makeContainer();
      final notifier = container.read(calendarControllerProvider.notifier);
      await notifier.moveTaskToDateTime(
        id,
        DateTime(today.year, today.month, today.day, 15, 0),
      );
      await drain();
      final t = (await db.getTask(id))!;
      expect(t.planStart!.hour, 15);
      expect(t.planEnd!.hour, 17);
    });
  });
}
