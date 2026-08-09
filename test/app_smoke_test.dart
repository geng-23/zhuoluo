import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/main.dart';

/// App 冒烟测试：验证启动、四 Tab、任务创建全流程
void main() {
  late AppDatabase db;

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
      ],
    );
    return container;
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 测试环境无音频插件，关闭动作音效
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('App 启动显示四栏并可在 Tab 间切换', (tester) async {
    await db.ensureDefaultList();
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZhuoluoApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 四栏导航存在（统计已移至"我的"页，四象限独立成 Tab）
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('日历'), findsOneWidget);
    expect(find.text('四象限'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);

    // 默认任务页显示"全部"
    expect(find.text('全部'), findsWidgets);

    // 切到日历（E12：功能在侧边栏，主区默认周视图）
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    // 打开侧边栏验证视图切换
    await tester.tap(find.byIcon(Icons.menu).last);
    await tester.pumpAndSettle();
    expect(find.text('月视图'), findsOneWidget);
    expect(find.text('周视图'), findsOneWidget);
    expect(find.text('日视图'), findsOneWidget);
    expect(find.text('今天'), findsWidgets);
    await tester.tapAt(const Offset(700, 100));
    await tester.pumpAndSettle();

    // 切到四象限 Tab
    await tester.tap(find.text('四象限'));
    await tester.pumpAndSettle();
    expect(find.text('重要紧急'), findsOneWidget);

    // 切到我的（统计入口在此）
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('番茄专注'), findsOneWidget);
    expect(find.text('习惯打卡'), findsOneWidget);
    expect(find.text('统计'), findsWidgets); // 分组标题 + 入口
    // 纪念日已删除（#28）
    expect(find.text('倒数纪念日'), findsNothing);

    // 关于：版本号 + 点击弹窗含联系方式（不写死版本号，避免升级后失配）
    await tester.scrollUntilVisible(find.textContaining('着落 v'), 200,
        scrollable: find.byType(Scrollable).last);
    // 多滚一段，避免条目停在底部导航栏后方被遮挡
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.textContaining('着落 v'), findsOneWidget);
    expect(find.text('无账号'), findsNothing);
    await tester.tap(find.textContaining('着落 v'));
    await tester.pumpAndSettle();
    expect(find.textContaining('confusion_geng@protonmail.com'), findsOneWidget,
        reason: '关于弹窗应显示联系方式');
    expect(find.textContaining('本地待办'), findsOneWidget,
        reason: '关于弹窗应有一句话介绍');
  });

  testWidgets('通过 FAB 快速添加任务（智能时间解析）', (tester) async {
    await db.ensureDefaultList();
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZhuoluoApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 点 FAB 打开快速添加
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // 输入智能时间文本
    await tester.enterText(
        find.byType(TextField).last, '明天下午3点交报告');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 任务出现在列表中
    expect(find.text('交报告'), findsWidgets);
  });

  testWidgets('数据库：清单/任务/完成/恢复全流程', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();

    final taskId = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '写周报',
      planStart: Value(DateTime(2026, 8, 10)),
      planEnd: Value(DateTime(2026, 8, 11)),
      isAllDay: const Value(true),
      createdAt: DateTime.now(),
    ));

    // 完成
    await db.completeTask(taskId);
    final doneTask = await db.getTask(taskId);
    expect(doneTask!.completedAt, isNotNull);

    // 恢复
    await db.reopenTask(taskId);
    final reopened = await db.getTask(taskId);
    expect(reopened!.completedAt, isNull);

    // 子任务自动联动
    final parentId = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '项目',
      createdAt: DateTime.now(),
    ));
    final sub1 = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      parentId: Value(parentId),
      title: '子1',
      createdAt: DateTime.now(),
    ));
    final sub2 = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      parentId: Value(parentId),
      title: '子2',
      createdAt: DateTime.now(),
    ));
    await db.completeTask(sub1);
    await db.maybeAutoCompleteParent(parentId);
    var parent = await db.getTask(parentId);
    expect(parent!.completedAt, isNull, reason: '子任务未全部完成');
    // 子任务不进入"全部"清单（只显示顶层任务）
    final uncompleted = await db.getAllUncompleted();
    expect(uncompleted.any((t) => t.title == '子2'), isFalse,
        reason: '未完成的子任务不出现在全部清单');
    expect(uncompleted.any((t) => t.title == '项目'), isTrue);
    await db.completeTask(sub2);
    await db.maybeAutoCompleteParent(parentId);
    parent = await db.getTask(parentId);
    expect(parent!.completedAt, isNotNull, reason: '子任务全完成父任务自动完成');
    // 子任务不进入"已完成"清单
    final done = await db.getCompletedTasks();
    expect(done.any((t) => t.title == '子1'), isFalse,
        reason: '子任务不出现在已完成清单');
    expect(done.any((t) => t.title == '子2'), isFalse);
  });

  testWidgets('数据库：重复任务实例完成与跳过', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();

    final taskId = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '每周五例会',
      planStart: Value(DateTime(2026, 8, 7, 14, 0)),
      planEnd: Value(DateTime(2026, 8, 7, 15, 0)),
      rrule: const Value('FREQ=WEEKLY;BYDAY=FR'),
      createdAt: DateTime.now(),
    ));

    // 实例完成
    await db.completeInstance(taskId, DateTime(2026, 8, 7));
    final done1 = await db.isInstanceCompleted(taskId, DateTime(2026, 8, 7));
    final done2 = await db.isInstanceCompleted(taskId, DateTime(2026, 8, 14));
    expect(done1, isTrue);
    expect(done2, isFalse, reason: '其他实例不受影响');

    // 日历展开
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 31),
    );
    final aug7 = items.where((i) =>
        i.instanceDate.month == 8 && i.instanceDate.day == 7);
    final aug14 = items.where((i) =>
        i.instanceDate.month == 8 && i.instanceDate.day == 14);
    expect(aug7.first.completed, isTrue);
    expect(aug14.first.completed, isFalse);
  });

  testWidgets('非重复任务完成状态在日历中正确显示', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();

    final taskId = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '普通任务',
      planStart: Value(DateTime(2026, 8, 10, 9, 0)),
      planEnd: Value(DateTime(2026, 8, 10, 10, 0)),
      createdAt: DateTime.now(),
    ));

    // 未完成时
    var items = await db.getCalendarItems(
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 31),
    );
    expect(items.firstWhere((i) => i.task.id == taskId).completed, isFalse);

    // 完成后
    await db.completeTask(taskId);
    items = await db.getCalendarItems(
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 31),
    );
    expect(items.firstWhere((i) => i.task.id == taskId).completed, isTrue,
        reason: '非重复任务完成后日历应显示完成状态');
  });

  testWidgets('数据库：习惯提醒时间可更新与清除', (tester) async {
    final id = await db.insertHabit('阅读', '📚', null);
    final created = await db.getHabit(id);
    expect(created!.reminderTime, isNull);

    await db.updateHabitReminder(id, DateTime(2026, 8, 6, 9, 0));
    final withRemind = await db.getHabit(id);
    expect(withRemind!.reminderTime, DateTime(2026, 8, 6, 9, 0));

    await db.updateHabitReminder(id, null);
    final cleared = await db.getHabit(id);
    expect(cleared!.reminderTime, isNull, reason: '清除提醒后应回到 null');
  });
}
