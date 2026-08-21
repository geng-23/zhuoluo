import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';

/// 统计页完成率柱状图：分桶聚合（周=7天 / 月=自然周 / 年=12月）
/// 与页面三档切换渲染。
void main() {
  // 固定"今天"：2026-08-18（周二）——该周周一起始为 2026-08-17；
  // 2026-08-01 为周六，8 月的周一起始自然周为
  // 7/27-8/2, 8/3-8/9, 8/10-8/16, 8/17-8/23, 8/24-8/30, 8/31-9/6。
  final fixedNow = DateTime(2026, 8, 18, 12, 0);

  /// 2026 年某月某日的应用时区"当天 00:00"键
  DateTime d(int day, [int month = 8]) => AppClock.at(2026, month, day);

  setUp(() => AppClock.setNow(fixedNow));
  tearDown(() => AppClock.setNow(null));

  group('completionBuckets 分桶聚合', () {
    test('周视图：周一~周日 7 桶，标签与数值正确', () {
      final completed = {d(17): 2, d(18): 1, d(23): 3};
      final planned = {d(17): 5, d(18): 2, d(23): 4};
      final buckets = completionBuckets(
        range: 'week',
        now: fixedNow,
        completed: completed,
        planned: planned,
      );
      expect(
        buckets.map((b) => b.label).toList(),
        ['周一', '周二', '周三', '周四', '周五', '周六', '周日'],
      );
      expect(buckets[0].completed, 2);
      expect(buckets[0].planned, 5);
      expect(buckets[1].completed, 1);
      expect(buckets[1].planned, 2);
      // 周六（8/22）无任务，周日（8/23）只计计划
      expect(buckets[5].completed, 0);
      expect(buckets[5].planned, 0);
      expect(buckets[6].completed, 3);
      expect(buckets[6].planned, 4);
    });

    test('月视图：周一起始自然周分桶，跨月周只计当月日期', () {
      final completed = {d(1): 1, d(3): 2, d(31): 3};
      final planned = {d(1): 5, d(15): 2, d(31): 4};
      final buckets = completionBuckets(
        range: 'month',
        now: fixedNow,
        completed: completed,
        planned: planned,
      );
      expect(buckets.length, 6);
      expect(
        buckets.map((b) => b.label).toList(),
        ['7/27-8/2', '8/3-8/9', '8/10-8/16', '8/17-8/23', '8/24-8/30', '8/31-9/6'],
      );
      // 首桶 7/27-8/2：7/27-7/31 在窗口外无键取 0，只计 8/1、8/2
      expect(buckets[0].planned, 5);
      expect(buckets[0].completed, 1);
      // 次桶 8/3-8/9
      expect(buckets[1].completed, 2);
      // 第 3 桶 8/10-8/16
      expect(buckets[2].planned, 2);
      // 末桶 8/31-9/6：9/1-9/6 在窗口外，只计 8/31
      expect(buckets[5].planned, 4);
      expect(buckets[5].completed, 3);
    });

    test('年视图：12 桶按月聚合', () {
      final completed = {d(1, 1): 5, d(15, 3): 2, d(18, 12): 1};
      final planned = {d(1, 1): 10, d(18, 8): 7};
      final buckets = completionBuckets(
        range: 'year',
        now: fixedNow,
        completed: completed,
        planned: planned,
      );
      expect(buckets.length, 12);
      expect(
        buckets.map((b) => b.label).toList(),
        ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'],
      );
      expect(buckets[0].planned, 10);
      expect(buckets[0].completed, 5);
      expect(buckets[2].completed, 2);
      expect(buckets[7].planned, 7);
      expect(buckets[11].completed, 1);
    });

    test('空数据：所有桶均为 0', () {
      final buckets = completionBuckets(
        range: 'year',
        now: fixedNow,
        completed: {},
        planned: {},
      );
      expect(buckets.length, 12);
      expect(buckets.every((b) => b.completed == 0 && b.planned == 0), isTrue);
    });
  });

  group('barMetrics 柱几何（等高 + 比例填充）', () {
    test('有计划的桶：总任务柱满高（等高），填充按完成/计划比例', () {
      final m = barMetrics(4, 2);
      expect(m.totalHeight, 100, reason: 'planned>0 总任务柱满高');
      expect(m.fillHeight, 50, reason: '填充 = 满高 × 2/4');
      expect(m.percent, '50%');
    });

    test('完成数 = 计划数 → 满填充 100%；完成数超过计划数 → 封顶 100%', () {
      expect(barMetrics(4, 4).fillHeight, 100);
      expect(barMetrics(4, 4).percent, '100%');
      expect(barMetrics(4, 8).fillHeight, 100,
          reason: '补做遗留任务完成数>计划数，封顶 100%');
      expect(barMetrics(4, 8).percent, '100%');
    });

    test('极小比例填充下限 2px 保证可见（1/1000）', () {
      final m = barMetrics(1000, 1);
      expect(m.totalHeight, 100);
      expect(m.fillHeight, 2, reason: '完成>0 时填充至少 2px，不得不可见');
      expect(m.percent, '0%');
    });

    test('有计划未完成：填充为 0（不渲染），百分比 0%', () {
      final m = barMetrics(4, 0);
      expect(m.totalHeight, 100);
      expect(m.fillHeight, 0);
      expect(m.percent, '0%');
    });

    test('无计划但有完成（补做）：总任务柱矮柱、填充满高、柱顶 100%', () {
      final m = barMetrics(0, 3);
      expect(m.totalHeight, 2);
      expect(m.fillHeight, 100, reason: '无比例可算，按 C7-1 封顶口径满填充');
      expect(m.percent, '100%');
    });

    test('无计划无完成：矮柱、无填充、柱顶 —', () {
      final m = barMetrics(0, 0);
      expect(m.totalHeight, 2);
      expect(m.fillHeight, 0);
      expect(m.percent, '—');
    });
  });

  group('跨天任务按开始日计入计划数', () {
    test('非重复跨天任务（周一22:00-周二06:00）只计开始日', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final mon = AppClock.at(2026, 8, 17); // 周一
      final tue = AppClock.at(2026, 8, 18); // 周二
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '跨天任务',
        planStart: Value(AppClock.at(2026, 8, 17, 22)),
        planEnd: Value(AppClock.at(2026, 8, 18, 6)),
        createdAt: fixedNow,
      ));

      final monCount = await db.getPlannedCountByDay(mon, mon);
      expect(monCount[mon], 1, reason: '按开始时刻计入周一');
      final tueCount = await db.getPlannedCountByDay(tue, tue);
      expect(tueCount[tue], isNull,
          reason: '跨天覆盖日周二不得重复计入');
      final weekCount = await db.getPlannedCountByDay(mon, AppClock.at(2026, 8, 23));
      expect(weekCount.values.fold<int>(0, (a, b) => a + b), 1,
          reason: '整周合计只计 1 项（开始日）');

      await db.close();
    });

    test('重复跨天任务实例只计规则命中日（开始日），覆盖日不计', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      // 每周一 22:00 - 周二 06:00 的跨天重复任务，锚点 8/17（周一）
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '每周跨天',
        rrule: const Value('FREQ=WEEKLY'),
        planStart: Value(AppClock.at(2026, 8, 17, 22)),
        planEnd: Value(AppClock.at(2026, 8, 18, 6)),
        createdAt: fixedNow,
      ));

      final weekCount = await db.getPlannedCountByDay(
        AppClock.at(2026, 8, 17),
        AppClock.at(2026, 8, 23),
      );
      // 锚点日按原口径计 2：planStart 计 1 + 实例展开计 1（与
      // timezone_semantics_test 的"重复任务 planStart 额外计 1 次"一致）
      expect(weekCount[AppClock.at(2026, 8, 17)], 2,
          reason: '周一（锚点/开始日）按原口径计 2（planStart + 实例）');
      expect(weekCount[AppClock.at(2026, 8, 18)], isNull,
          reason: '周二覆盖日不计入');
      expect(weekCount.values.fold<int>(0, (a, b) => a + b), 2);

      await db.close();
    });

    test('完成数按计划日归组：周四计划周五完成的任务计入周四，不计周五', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final thu = AppClock.at(2026, 8, 20);
      final fri = AppClock.at(2026, 8, 21);
      // 周四 10:50 计划、周五 14:53 才完成（补做）
      final id = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '补做任务',
        planStart: Value(AppClock.at(2026, 8, 20, 10, 50)),
        planEnd: Value(AppClock.at(2026, 8, 20, 12, 10)),
        createdAt: fixedNow,
      ));
      // 完成时刻 = 周五（模拟补做）
      AppClock.setNow(AppClock.at(2026, 8, 21, 14, 53));
      await db.completeTask(id);
      AppClock.setNow(fixedNow);

      final thuCount = await db.getCompletedCountByDay(thu, thu);
      expect(thuCount[thu], 1, reason: '完成数按计划开始日（周四）计入');
      final friCount = await db.getCompletedCountByDay(fri, fri);
      expect(friCount[fri], isNull,
          reason: '周五不得出现该任务的完成（补做不按完成时刻归日）');
      // 与计划数同口径：周四 1/1，周五 0/0
      final thuPlanned = await db.getPlannedCountByDay(thu, thu);
      expect(thuPlanned[thu], 1);

      await db.close();
    });

    test('无计划时间的任务完成不计入完成数（与计划数口径一致）', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final today = AppClock.at(2026, 8, 21);
      final id = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '无时间任务',
        createdAt: fixedNow,
      ));
      await db.completeTask(id);

      final counts = await db.getCompletedCountByDay(today, today);
      expect(counts.values.fold<int>(0, (a, b) => a + b), 0,
          reason: '无 planStart/dueTime 的任务既不进计划数也不进完成数');
      final planned = await db.getPlannedCountByDay(today, today);
      expect(planned.values.fold<int>(0, (a, b) => a + b), 0);

      await db.close();
    });
  });

  group('统计页柱状图渲染', () {
    testWidgets('周/月/年三档切换：桶标签、x/y 图注与百分比正确', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      final list = await db.getDefaultList();

      // 本周内预置任务：
      // A 周一 8/17 计划 1 完成 1；B 周一 8/17 计划 1 未完成；
      // C 周二 8/18 计划 1 完成 1；D 周三 8/19 计划 1 未完成
      Future<void> seed(DateTime start, {required bool done}) async {
        final id = await db.insertTask(TasksCompanion.insert(
          listId: list.id,
          title: '任务${start.month}/${start.day}',
          planStart: Value(start),
          planEnd: Value(AppClock.addCalendarDays(start, 1)),
          createdAt: fixedNow,
        ));
        if (done) {
          // 完成时间 = 计划日当天（写库用 AppClock.now()，临时拨钟）
          AppClock.setNow(start);
          await db.completeTask(id);
          AppClock.setNow(fixedNow);
        }
      }

      await seed(AppClock.at(2026, 8, 17, 9), done: true);
      await seed(AppClock.at(2026, 8, 17, 10), done: false);
      await seed(AppClock.at(2026, 8, 18, 9), done: true);
      await seed(AppClock.at(2026, 8, 19, 9), done: false);

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

      // ---- 月视图（页面默认）：8/17-8/23 桶 完成2/总4，其余 5 桶空 ----
      expect(find.text('完成率'), findsOneWidget);
      expect(find.text('7/27-8/2'), findsOneWidget);
      expect(find.text('8/17-8/23'), findsOneWidget);
      expect(find.text('8/31-9/6'), findsOneWidget);
      expect(find.text('2/4'), findsOneWidget);
      // 头部完成率 50%（4 计划 2 完成）+ 8/17-8/23 桶 50%
      expect(find.text('50%'), findsNWidgets(2));
      expect(find.text('0/0'), findsNWidgets(5));
      expect(find.text('—'), findsNWidgets(5));

      // ---- 周视图：周一(1/2) 周二(1/1) 周三(0/1) 其余 0/0 ----
      await tester.tap(find.text('周'));
      await tester.pumpAndSettle();
      for (final w in ['周一', '周二', '周三', '周四', '周五', '周六', '周日']) {
        expect(find.text(w), findsOneWidget, reason: '周视图应显示 $w');
      }
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('1/1'), findsOneWidget);
      expect(find.text('0/1'), findsOneWidget);
      expect(find.text('0/0'), findsNWidgets(4));
      expect(find.text('50%'), findsNWidgets(2));
      expect(find.text('100%'), findsOneWidget); // 周二桶
      expect(find.text('0%'), findsOneWidget); // 周三桶
      expect(find.text('—'), findsNWidgets(4)); // 周四~周日

      // ---- 年视图：8月桶 完成2/总4（紧凑格式 2/4），其余 11 月空 ----
      await tester.tap(find.text('年'));
      await tester.pumpAndSettle();
      expect(find.text('8月'), findsOneWidget);
      expect(find.text('1月'), findsOneWidget);
      expect(find.text('12月'), findsOneWidget);
      expect(find.text('2/4'), findsOneWidget);
      expect(find.text('50%'), findsNWidgets(2));
      expect(find.text('0/0'), findsNWidgets(11));
      expect(find.text('—'), findsNWidgets(11));

      await db.close();
      container.dispose();
    });

    testWidgets('无数据时显示"该时段无计划任务"，不渲染柱状图', (tester) async {
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

      expect(find.text('该时段无计划任务'), findsOneWidget);
      expect(find.text('总任务'), findsNothing);
      expect(find.text('已完成'), findsNothing);

      await db.close();
      container.dispose();
    });
  });
}
