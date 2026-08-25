import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/statistics/pomodoro_stats_page.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';

/// 专注详情页：时长文案、周/月/年/全部统计、日×任务聚合明细、
/// 任务分布前 4 + 其他、多选删除与撤销、统计页入口
///
/// 固定 AppClock.now = 2026-08-20 15:00（周四），记录用
/// insertPomodoroRaw 显式写 completedAt，保证区间断言确定。
void main() {
  group('formatFocusMinutes', () {
    test('各档位中文时长文案', () {
      expect(formatFocusMinutes(0), '0 分钟');
      expect(formatFocusMinutes(45), '45 分钟');
      expect(formatFocusMinutes(60), '1小时');
      expect(formatFocusMinutes(90), '1小时30分');
      expect(formatFocusMinutes(150), '2小时30分');
    });
  });

  group('专注详情页', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      AppClock.setNow(DateTime(2026, 8, 20, 15, 0));
      container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
      ]);
      addTearDown(container.dispose);
    });

    tearDown(() async {
      AppClock.setNow(null);
      await db.close();
    });

    /// 种子数据（completedAt 显式指定）：
    /// - 今天(8-20)：写方案 25 分 + 自由专注 15 分
    /// - 昨天(8-19)：读文献 45 分
    /// - 8-13：写方案 30 分；7-15：写方案 60 分；2025-12-10：读文献 50 分
    /// - 另加一条 0 分钟记录（立即结束）：不计次数、不进明细
    Future<void> seed() async {
      final list = await db.getDefaultList();
      final taskA = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '写方案',
        createdAt: DateTime(2026, 8, 1),
      ));
      final taskB = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '读文献',
        createdAt: DateTime(2026, 8, 1),
      ));
      Future<void> add(int? taskId, int minutes, DateTime start) => db
          .insertPomodoroRaw(
            PomodoroRecordsCompanion.insert(
              taskId: Value(taskId),
              durationMinutes: minutes,
              startedAt: start,
              completedAt: start.add(Duration(minutes: minutes)),
            ),
          );
      await add(taskA, 25, DateTime(2026, 8, 20, 9, 0));
      await add(null, 15, DateTime(2026, 8, 20, 10, 0));
      await add(taskB, 45, DateTime(2026, 8, 19, 14, 0));
      await add(taskA, 30, DateTime(2026, 8, 13, 11, 0));
      await add(taskA, 60, DateTime(2026, 7, 15, 9, 0));
      await add(taskB, 50, DateTime(2025, 12, 10, 20, 0));
      await add(null, 0, DateTime(2026, 8, 20, 12, 0));
    }

    /// 新增任务并添加一条当日记录
    Future<int> seedTaskWithRecord(String title, int minutes) async {
      final list = await db.getDefaultList();
      final id = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: title,
        createdAt: DateTime(2026, 8, 1),
      ));
      await db.insertPomodoroRaw(
        PomodoroRecordsCompanion.insert(
          taskId: Value(id),
          durationMinutes: minutes,
          startedAt: DateTime(2026, 8, 20, 8, 0),
          completedAt: DateTime(2026, 8, 20, 8, 0)
              .add(Duration(minutes: minutes)),
        ),
      );
      return id;
    }

    Future<void> pumpPage(WidgetTester tester) async {
      // 加高视口：明细列表/图表卡片全部在首屏内构建（默认 600px 高
      // 时 ListView 惰性构建只渲染可视区，下方断言会找不到控件）
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: PomodoroStatsPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('空数据：显示空态引导', (tester) async {
      await pumpPage(tester);
      expect(find.text('专注详情'), findsOneWidget);
      expect(find.text('还没有专注记录'), findsOneWidget);
      expect(find.text('去"我的 > 番茄专注"开始第一次专注'), findsOneWidget);
    });

    testWidgets('月视图：周桶柱状图 + 汇总 + 日×任务聚合明细（不罗列每次会话）', (tester) async {
      await seed();
      await pumpPage(tester);

      // 汇总：8 月窗口 25+15+45+30 = 115 分 = 1小时55分，4 次
      // （0 分钟记录不计次数）；平均每天 = round(115/31) = 4 分钟
      expect(find.text('1小时55分'), findsNWidgets(2),
          reason: '总时长卡与环形图中心都显示总时长');
      expect(find.text('4 次'), findsOneWidget);
      expect(find.text('4 分钟'), findsOneWidget);

      // 月档柱状图 = 每周聚合（周一起始自然周，标签 m/d-m/d）
      expect(find.text('每周专注时长'), findsOneWidget);
      expect(find.text('8/17-8/23'), findsOneWidget, reason: '8-19+8-20 所在周');
      expect(find.text('8/10-8/16'), findsOneWidget, reason: '8-13 所在周');
      expect(find.text('1.4时'), findsOneWidget, reason: '8/17-8/23 周 = 85 分');
      expect(find.text('30分'), findsOneWidget, reason: '8/10-8/16 周 = 30 分');

      // 明细：日头（今天/昨天/8月13日 周四）+ 当日合计 + 聚合行（任务 + N 次）
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('共 40 分钟'), findsOneWidget, reason: '今天 25+15 分');
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('共 45 分钟'), findsOneWidget);
      expect(find.text('8月13日 周四'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '写方案'), findsNWidgets(2),
          reason: '今天与 8-13 各一个聚合行');
      expect(find.widgetWithText(ListTile, '自由专注'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '读文献'), findsOneWidget);
      expect(find.text('1 次'), findsNWidgets(4), reason: '4 个聚合组各 1 次');
      // 不再罗列每次会话（无起止时间段文本）
      expect(find.textContaining('–'), findsNothing);

      // 任务分布：环形图图例（55/115=48%）
      expect(find.text('任务分布'), findsOneWidget);
      expect(find.text('48%'), findsOneWidget);
    });

    testWidgets('周/年/全部切换：窗口过滤与图表变化', (tester) async {
      await seed();
      await pumpPage(tester);

      // 周视图：8-17(周一)~8-23，含今天/昨天 = 25+15+45 = 85 分，3 次；
      // 8-13 记录在窗口外；7 根日柱柱顶显示时长
      await tester.tap(find.text('周'));
      await tester.pumpAndSettle();
      expect(find.text('每日专注时长'), findsOneWidget);
      expect(find.text('1小时25分'), findsNWidgets(2));
      expect(find.text('3 次'), findsOneWidget);
      expect(find.text('8月13日 周四'), findsNothing);
      expect(find.text('45分'), findsOneWidget, reason: '周三 45 分柱');

      // 年视图：2026 全年 = 115 + 7-15 的 60 分 = 175 分，5 次；
      // 2025-12-10 在窗口外
      await tester.tap(find.text('年'));
      await tester.pumpAndSettle();
      expect(find.text('每月专注时长'), findsOneWidget);
      expect(find.text('2小时55分'), findsNWidgets(2));
      expect(find.text('5 次'), findsOneWidget);
      expect(find.text('7月15日 周三'), findsOneWidget);
      expect(find.text('2025年12月10日'), findsNothing);

      // 全部：含 2025 年记录 = 225 分，6 次；跨年日头按年显示；
      // 全部档不显示柱状图板块
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(find.text('3小时45分'), findsNWidgets(2));
      expect(find.text('6 次'), findsOneWidget);
      expect(find.text('2025年12月10日'), findsOneWidget);
      expect(find.text('每月专注时长'), findsNothing, reason: '全部档无柱状图');
    });

    testWidgets('任务分布：仅前 4 个最长任务 + 其他（共 5 行）', (tester) async {
      // 6 个任务各 10 分钟（同日）→ 前 4 + 其他(20 分)
      for (var i = 1; i <= 6; i++) {
        await seedTaskWithRecord('任务$i', 10);
      }
      await pumpPage(tester);

      expect(find.text('其他'), findsOneWidget, reason: '第 5/6 名合并为其他');
      expect(find.text('20 分钟'), findsOneWidget, reason: '其他 = 20 分');
      expect(find.text('33%'), findsOneWidget, reason: '其他占比 20/60');
      expect(find.text('1小时'), findsNWidgets(2), reason: '汇总与环形图中心');
      expect(find.text('6 次'), findsOneWidget);
    });

    testWidgets('多选删除与撤销：长按进入多选、全选、确认删除、撤销恢复', (tester) async {
      await seed();
      await pumpPage(tester);

      // 长按明细行进入多选（已选 1 项）
      await tester.longPress(find.widgetWithText(ListTile, '写方案').first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);

      // 再点一行 → 已选 2 项
      await tester.tap(find.widgetWithText(ListTile, '自由专注'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);

      // 全选（月视图共 4 组）
      await tester.tap(find.byTooltip('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 4 项'), findsOneWidget);

      // 删除所选 → 确认弹窗 → 确认
      await tester.tap(find.byTooltip('删除所选'));
      await tester.pumpAndSettle();
      expect(find.text('删除所选专注记录？'), findsOneWidget);
      expect(find.text('将删除 4 条专注记录，删除后可撤销'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // 数据库 7 → 3 条（删掉月视图 4 组；7-15、2025-12-10 与 0 分钟保留）
      expect((await db.getPomodoros()).length, 3, reason: '删除后剩余记录');
      expect(find.text('已删除 4 条专注记录'), findsOneWidget);
      // 月视图无记录 → 空态
      expect(find.text('还没有专注记录'), findsOneWidget);

      // 撤销 → 恢复全部记录（含原 id）
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect((await db.getPomodoros()).length, 7, reason: '撤销恢复全部记录');
      expect(find.text('1小时55分'), findsNWidgets(2), reason: '撤销后数据复原');
    });

    testWidgets('手机尺寸（393x873 逻辑像素）下各档位渲染无溢出', (tester) async {
      // 回归：年档 12 根窄柱时柱顶数值文本换行曾导致
      // RenderFlex bottom overflow（设备上表现为 10px 红条）——
      // FittedBox 固定槽修复后，窄柱/长文本下不得再溢出
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> add(int? taskId, int minutes, DateTime start) => db
          .insertPomodoroRaw(
            PomodoroRecordsCompanion.insert(
              taskId: Value(taskId),
              durationMinutes: minutes,
              startedAt: start,
              completedAt: start.add(Duration(minutes: minutes)),
            ),
          );
      await add(null, 14, DateTime(2026, 8, 20, 9, 0));
      await add(null, 8, DateTime(2026, 8, 20, 10, 0));
      await add(null, 22, DateTime(2026, 8, 21, 9, 0));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: PomodoroStatsPage()),
        ),
      );
      await tester.pumpAndSettle();
      for (final r in ['月', '年', '全部', '周']) {
        await tester.tap(find.text(r));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
      }
    });

    testWidgets('窄屏（320dp）月档周桶标签经 FittedBox 缩放显示', (tester) async {
      // 回归：月档「8/17-8/23」等长标签在 <360dp 屏曾因 ellipsis 截断——
      // 标签行改 FittedBox(scaleDown) 后完整缩放显示
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await seed();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: PomodoroStatsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '窄屏渲染无异常');
      // 标签在 FittedBox 内完整存在且可显示（修复前为 ellipsis 截断）
      final labelInFittedBox = find.descendant(
        of: find.byType(FittedBox),
        matching: find.text('8/17-8/23'),
      );
      expect(labelInFittedBox, findsOneWidget, reason: '周桶标签应完整保留');
    });

    testWidgets('统计页点击专注时长卡片进入专注详情页', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: StatisticsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('专注时长'), findsOneWidget);

      await tester.tap(find.text('专注时长'));
      await tester.pumpAndSettle();
      expect(find.text('专注详情'), findsOneWidget);
      expect(find.text('还没有专注记录'), findsOneWidget, reason: '空库进入详情页');
    });
  });
}
