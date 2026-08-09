import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';

import '../support/fake_notification_scheduler.dart';

/// 任务详情页重复任务实例操作回归：
/// - 完成本次 → 撤销条 → 撤销后实例恢复且详情页刷新
/// - 撤销完成本次不再弹撤销条
/// - 全天任务改期本次不弹时间选择器（维持全天）
/// - 跳过本次 → "今天已跳过"占位 → 撤销 → 恢复"完成本次"
void main() {
  late AppDatabase db;
  final today =
      AppClock.at(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  /// 插入今天命中的每日重复任务（可设全天）
  Future<int> insertDailyTask({bool allDay = false}) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final day = today;
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每日任务',
      planStart: Value(day),
      planEnd: Value(allDay ? day.add(const Duration(hours: 24)) : day.add(const Duration(hours: 1))),
      isAllDay: Value(allDay),
      rrule: const Value('FREQ=DAILY'),
      createdAt: AppClock.now(),
    ));
  }

  Future<void> pumpDetail(WidgetTester tester, int taskId) async {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: TaskDetailPage(taskId: taskId)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('完成本次→撤销条→撤销：实例恢复且详情页刷新', (tester) async {
    final id = await insertDailyTask();
    await pumpDetail(tester, id);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '详情页应加载完成');
    expect(find.text('每日任务'), findsOneWidget, reason: '任务标题应显示');

    await tester.scrollUntilVisible(find.text('完成本次'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('完成本次'));
    await tester.pumpAndSettle();
    expect(await db.isInstanceCompleted(id, today), isTrue,
        reason: '完成本次写入实例完成记录');
    expect(find.text('已完成今天的实例'), findsOneWidget, reason: '完成后弹撤销条');
    expect(find.text('撤销完成本次'), findsOneWidget, reason: '详情页刷新为已完成');

    await tester.ensureVisible(find.text('撤销'));
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(await db.isInstanceCompleted(id, today), isFalse,
        reason: '撤销条撤销后实例恢复未完成');
    expect(find.text('完成本次'), findsOneWidget,
        reason: '详情页刷新：撤销后回到待完成');
  });

  testWidgets('撤销完成本次不弹撤销条', (tester) async {
    final id = await insertDailyTask();
    await db.completeInstance(id, today);
    await pumpDetail(tester, id);
    await tester.scrollUntilVisible(find.text('撤销完成本次'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('撤销完成本次'), findsOneWidget, reason: '今天已完成');

    await tester.tap(find.text('撤销完成本次'));
    await tester.pumpAndSettle();
    expect(await db.isInstanceCompleted(id, today), isFalse,
        reason: '撤销完成本次删除完成记录');
    expect(find.text('已撤销今天的完成'), findsNothing,
        reason: '撤销动作本身不应弹撤销条（避免撤销的撤销）');
    expect(find.text('完成本次'), findsOneWidget, reason: '刷新后回到待完成');
  });

  testWidgets('全天任务改期本次不弹时间选择器（维持全天）', (tester) async {
    final id = await insertDailyTask(allDay: true);
    await pumpDetail(tester, id);

    await tester.scrollUntilVisible(find.text('改期本次'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('改期本次'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget, reason: '先选日期');

    // 选当前日期并确认（Material 默认 en 本地化的确认按钮为 OK）
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing,
        reason: '全天任务改期本次不弹时间选择器');

    // 例外写入目标日 00:00（维持全天语义）
    final exceptions = await db.getExceptions(id);
    expect(exceptions, hasLength(1));
    final od = exceptions.single.overrideScheduledDate;
    expect(od, isNotNull);
    final a = AppClock.asApp(od!);
    expect(a.hour, 0, reason: '全天改期到 00:00');
    expect(a.minute, 0);
  });

  testWidgets('跳过本次→今天已跳过占位→撤销→恢复完成本次', (tester) async {
    final id = await insertDailyTask();
    await pumpDetail(tester, id);

    await tester.scrollUntilVisible(find.text('跳过本次'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('跳过本次'));
    await tester.pumpAndSettle();
    expect(find.text('今天已跳过'), findsOneWidget, reason: '跳过后显示占位');
    expect(find.text('完成本次'), findsNothing, reason: '跳过后完成选项消失');

    await tester.ensureVisible(find.text('撤销'));
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('今天已跳过'), findsNothing, reason: '撤销跳过后占位消失');
    expect(find.text('完成本次'), findsOneWidget, reason: '撤销跳过后完成选项恢复');
  });
}
