import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';

void main() {
  testWidgets('统计页完成率卡片正常渲染（含空数据）', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: StatisticsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('完成率'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('该时段无计划任务'), findsOneWidget);
    expect(find.text('专注时长'), findsOneWidget);

    // 年热力图渲染「1/1 至今」的全部已过天数（今天为最后一格红圈），
    // 不再为未来日期渲染透明占位格——消除底部大片留白
    final now = DateTime.now();
    final dayOfYear = AppClock.daysBetween(
          AppClock.at(now.year, 1, 1),
          AppClock.at(now.year, now.month, now.day),
        ) +
        1;
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, dayOfYear,
        reason: '热力图必须渲染 1/1 至今 $dayOfYear 天，不能裁剪');

    // 标题不再出现 GitHub 字样
    expect(find.textContaining('GitHub'), findsNothing);
    expect(find.text('${now.year} 年完成热力图'), findsOneWidget);
    expect(find.textContaining('共 $dayOfYear 天'), findsOneWidget);

    await db.close();
    container.dispose();
  });

  testWidgets('统计页习惯热力图标题含打卡热力图字样并标注近 90 天', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    await db.insertHabit('阅读', '📚', null);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: StatisticsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 标题明确是"打卡热力图"，并标注近 90 天起止区间
    expect(find.textContaining('打卡热力图'), findsOneWidget);
    expect(find.textContaining('近 90 天'), findsOneWidget);
    expect(find.textContaining('GitHub'), findsNothing);

    await db.close();
    container.dispose();
  });

  test('A1：统计完成数包含普通任务与重复任务实例', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 普通任务完成 → 计入（有计划开始日，按计划日归组）
    final t1 = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '普通任务',
      planStart: Value(today),
      planEnd: Value(today.add(const Duration(hours: 1))),
      createdAt: now,
    ));
    await db.completeTask(t1);

    // 重复任务实例完成 → 计入（task_completions，按实例日归组）
    final t2 = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '重复任务',
      rrule: const Value('FREQ=DAILY'),
      planStart: Value(today),
      planEnd: Value(today.add(const Duration(hours: 1))),
      createdAt: now,
    ));
    await db.completeInstance(t2, today);

    final counts = await db.getCompletedCountByDay(today, today);
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    expect(total, 2, reason: '普通任务 + 重复实例应都计入统计');

    await db.close();
  });
}
