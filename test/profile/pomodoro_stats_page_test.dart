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

/// 专注详情页：时长文案、周/月/年/全部统计、明细列表、统计页入口
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

    testWidgets('月视图：汇总、明细（日期/任务/时长）、0 分钟记录被跳过', (tester) async {
      await seed();
      await pumpPage(tester);

      // 汇总：8 月窗口 25+15+45+30 = 115 分 = 1小时55分，4 次
      // （0 分钟记录不计次数）；平均每天 = round(115/31) = 4 分钟
      expect(find.text('1小时55分'), findsNWidgets(2),
          reason: '总时长卡与环形图中心都显示总时长');
      expect(find.text('4 次'), findsOneWidget);
      expect(find.text('4 分钟'), findsOneWidget);

      // 明细：日头（今天/昨天/8月13日 周四）+ 当日合计 + 记录
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('共 40 分钟'), findsOneWidget, reason: '今天 25+15 分');
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('共 45 分钟'), findsOneWidget);
      expect(find.text('8月13日 周四'), findsOneWidget);
      expect(find.text('写方案'), findsWidgets, reason: '明细与任务分布图例均含任务名');
      expect(find.text('自由专注'), findsWidgets);
      expect(find.text('读文献'), findsWidgets);
      expect(find.text('09:00–09:25'), findsOneWidget, reason: '起止时间段');
      // 0 分钟记录不进明细（12:00–12:00 不应出现）
      expect(find.text('12:00–12:00'), findsNothing);

      // 任务分布：环形图图例（55/115=48%）
      expect(find.text('任务分布'), findsOneWidget);
      expect(find.text('48%'), findsOneWidget);
    });

    testWidgets('周/年/全部切换：窗口过滤与月柱图', (tester) async {
      await seed();
      await pumpPage(tester);

      // 周视图：8-17(周一)~8-23，含今天/昨天 = 25+15+45 = 85 分，3 次；
      // 8-13 记录在窗口外
      await tester.tap(find.text('周'));
      await tester.pumpAndSettle();
      expect(find.text('1小时25分'), findsNWidgets(2));
      expect(find.text('3 次'), findsOneWidget);
      expect(find.text('8月13日 周四'), findsNothing);
      // 周档 7 根柱 ≤12 → 柱顶显示时长（45 分柱）
      expect(find.text('45分'), findsOneWidget);

      // 年视图：2026 全年 = 115 + 7-15 的 60 分 = 175 分，5 次；
      // 2025-12-10 在窗口外
      await tester.tap(find.text('年'));
      await tester.pumpAndSettle();
      expect(find.text('2小时55分'), findsNWidgets(2));
      expect(find.text('5 次'), findsOneWidget);
      expect(find.text('7月15日 周三'), findsOneWidget);
      expect(find.text('2025年12月10日'), findsNothing);

      // 全部：含 2025 年记录 = 225 分，6 次；跨年日头按年显示
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(find.text('3小时45分'), findsNWidgets(2));
      expect(find.text('6 次'), findsOneWidget);
      expect(find.text('2025年12月10日'), findsOneWidget);
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
