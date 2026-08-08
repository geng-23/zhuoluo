import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/task/task_page.dart';

/// 搜索 UI 与通知测试入口回归测试
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  group('搜索 UI：右上角入口', () {
    testWidgets('点搜索图标进入搜索模式，输入即搜，关闭可退出', (tester) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '交报告',
        createdAt: now,
      ));
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '买牛奶',
        createdAt: now,
      ));

      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TaskPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 点右上角搜索图标 → 进入搜索模式（出现搜索输入框）
      expect(find.text('交报告'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      expect(find.text('搜索标题或备注'), findsOneWidget,
          reason: '搜索图标应进入 AppBar 内嵌搜索框（此前点了没反应）');

      // 输入即搜
      await tester.enterText(find.byType(TextField), '报告');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('交报告'), findsOneWidget);
      expect(find.text('买牛奶'), findsNothing);
      expect(find.textContaining('找到'), findsOneWidget,
          reason: '显示结果计数');

      // 关闭退出搜索模式
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('搜索标题或备注'), findsNothing);
      expect(find.text('买牛奶'), findsOneWidget,
          reason: '退出搜索回到全部视图');
    });

    testWidgets('搜索结果为空时显示关键词与清除按钮', (tester) async {
      await db.ensureDefaultList();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TaskPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '不存在的词');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('没有找到与「不存在的词」'), findsOneWidget);

      await tester.tap(find.text('清除搜索'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('搜索标题或备注'), findsNothing,
          reason: '清除搜索后退出搜索模式');
    });
  });

  group('通知测试 ID 区段', () {
    test('测试通知 ID 不与任务/习惯区段重叠', () {
      final testId = NotificationIds.forTest;
      final habitId = NotificationIds.forHabit(1);
      final taskId = NotificationIds.forReminder(1, DateTime(2026, 8, 10));
      expect(testId, isNot(equals(habitId)));
      expect(testId, isNot(equals(taskId)));
      // P0-7：测试段在 int32 上限附近，高于习惯段（习惯段 = 2.1e9 - habitId）
      expect(testId, greaterThan(habitId));
    });
  });
}
