import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/profile/profile_page.dart';
import 'package:zhuoluo/features/task/task_page.dart';

/// 语义修正回归测试（docs/00-code-audit-and-correctness-plan.md 第 5 章）
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

  group('5.2 重复任务进入"已完成"视图', () {
    test('今日实例完成的重复任务出现在已完成，撤销后消失', () async {
      final id = await insertTask(
        title: '每日任务',
        rrule: 'FREQ=DAILY',
        planStart: today,
      );
      await db.completeInstance(id, today);
      final done = await db.getCompletedTasks();
      expect(done.map((t) => t.id), contains(id),
          reason: '5.2：今日实例完成的重复任务应出现在已完成视图');

      await db.uncompleteInstance(id, today);
      final done2 = await db.getCompletedTasks();
      expect(done2.map((t) => t.id), isNot(contains(id)),
          reason: '撤销今日实例后从已完成视图消失');
    });

    test('普通任务完成行为不受影响', () async {
      final id = await insertTask(title: '普通任务');
      await db.completeTask(id);
      final done = await db.getCompletedTasks();
      expect(done.map((t) => t.id), contains(id));
    });
  });

  group('5.4 习惯通知定位', () {
    testWidgets('initialHabitId 时滚动定位到目标习惯并高亮', (tester) async {
      await db.ensureDefaultList();
      // 创建 15 个习惯，目标在列表中部（超出首屏）
      int targetId = 0;
      for (var i = 0; i < 15; i++) {
        final id = await db.insertHabit('习惯$i', '⭐', null);
        if (i == 11) targetId = id;
      }
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: HabitPage(initialHabitId: targetId)),
        ),
      );
      await tester.pumpAndSettle();

      // 目标习惯被滚动到可见区域（默认首屏只显示前 ~8 项）
      expect(find.text('习惯11'), findsOneWidget,
          reason: '5.4：通知点击后应定位到目标习惯');
    });
  });

  group('5.9 快速添加按钮文案', () {
    testWidgets('"更多字段"改为"添加并编辑"', (tester) async {
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
      expect(find.text('添加并编辑'), findsOneWidget);
      expect(find.text('更多字段'), findsNothing);
    });
  });
}
