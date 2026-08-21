import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/features/statistics/pomodoro_stats_page.dart';

/// 统计页：完成率趋势 / 完成分布 / 专注时长 / 习惯热力图 / 年视图热力图
class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});

  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  String _range = 'month'; // week / month / year
  Map<DateTime, int> _completed = {};
  Map<DateTime, int> _planned = {};
  Map<DateTime, int> _pomodoros = {};
  // F1：按习惯分组的热力图数据
  List<Habit> _habits = [];
  Map<int, Map<DateTime, bool>> _habitHeatByHabit = {};
  bool _loading = true;

  /// _load 请求序号——丢弃过期结果（快速切换周/月/年时旧请求
  /// 不得覆盖新选择）
  int _loadSeq = 0;
  late final ProviderSubscription<int> _dataSub;

  @override
  void initState() {
    super.initState();
    // B2：任务数据变更（完成/添加等）自动刷新统计
    // listenManual 需在 dispose 中 close（否则每次进出页面泄漏订阅）
    _dataSub = ref.listenManual<int>(dataVersionProvider, (prev, next) {
      if (prev != next) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _dataSub.close();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final db = ref.read(dbProvider);
    final now = AppClock.now();
    DateTime from;
    DateTime to;
    switch (_range) {
      case 'week':
        from = DateUtilsEx.mondayOf(now);
        to = AppClock.addCalendarDays(from, 6);
        break;
      case 'month':
        from = AppClock.at(now.year, now.month, 1);
        to = AppClock.at(now.year, now.month + 1, 0);
        break;
      case 'year':
        from = AppClock.at(now.year, 1, 1);
        to = AppClock.at(now.year, 12, 31);
        break;
      default:
        from = AppClock.at(now.year, now.month, 1);
        to = AppClock.at(now.year, now.month + 1, 0);
    }
    // 三个计数查询相互独立，并行执行——计划数展开（年视图逐日展开重复
    // 任务）最慢，若顺序 await 会拖住完成数/专注数据的整体刷新（此前
    // 数据变更后已完成柱"不能及时渲染"）
    final (completed, planned, pomodoros) = await (
      db.getCompletedCountByDay(from, to),
      db.getPlannedCountByDay(from, to),
      db.getPomodoros(from: from, to: to),
    ).wait;

    // F1：习惯热力图（每个习惯独立）
    final habits = await db.getHabits();
    // 90 天窗口按"日历日"展开（今天 00:00 起往回 89 天），跨 DST 转换日
    // 不得因 ±1 小时漂移成 89/91 个日历日
    final habitStart = AppClock.addCalendarDays(
      AppClock.startOfDay(now),
      -89,
    );
    final heatByHabit = <int, Map<DateTime, bool>>{};
    for (final h in habits) {
      final map = <DateTime, bool>{};
      for (var d = 0; d < 90; d++) {
        final day = AppClock.addCalendarDays(habitStart, d);
        map[AppClock.at(day.year, day.month, day.day)] = false;
      }
      heatByHabit[h.id] = map;
    }
    final records = await db.getAllHabitRecords();
    for (final r in records) {
      // ：r.date 为 DB 读回值，字段按应用时区解释后与热力图 key 对齐
      final a = AppClock.asApp(r.date);
      final day = AppClock.at(a.year, a.month, a.day);
      final map = heatByHabit[r.habitId];
      if (map != null && map.containsKey(day)) {
        map[day] = true;
      }
    }

    if (mounted && seq == _loadSeq) {
      setState(() {
        _completed = completed;
        _planned = planned;
        _pomodoros = _pomodoroDayMap(pomodoros);
        _habits = habits;
        _habitHeatByHabit = heatByHabit;
        _loading = false;
      });
    }
  }

  Map<DateTime, int> _pomodoroDayMap(List<PomodoroRecord> records) {
    final map = <DateTime, int>{};
    for (final r in records) {
      // ：completedAt 为 DB 读回值，字段按应用时区解释后分组
      final a = AppClock.asApp(r.completedAt);
      final d = AppClock.at(a.year, a.month, a.day);
      map[d] = (map[d] ?? 0) + r.durationMinutes;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'week', label: Text('周')),
              ButtonSegment(value: 'month', label: Text('月')),
              ButtonSegment(value: 'year', label: Text('年')),
            ],
            selected: {_range},
            onSelectionChanged: (s) {
              setState(() {
                _range = s.first;
                _loading = true;
              });
              _load();
            },
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _CompletionCard(
                  completed: _completed,
                  planned: _planned,
                  range: _range,
                ),
                const SizedBox(height: 16),
                _PomodoroCard(days: _pomodoros),
                const SizedBox(height: 16),
                // F1：每个习惯独立热力图
                for (final h in _habits) ...[
                  _HabitHeatmap(
                    habitName: h.name,
                    icon: h.icon,
                    heat: _habitHeatByHabit[h.id] ?? {},
                  ),
                  const SizedBox(height: 16),
                ],
                if (_habits.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '还没有习惯，去"我的 > 习惯打卡"添加',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  ),
                // key 随加载序号变化 → 数据刷新时重建（此前 State 复用
                // 不重跑 initState，热力图在页面存活期间不更新）
                _YearHeatmap(key: ValueKey(_loadSeq), db: ref.read(dbProvider)),
              ],
            ),
    );
  }
}

/// 柱状图分桶：某统计区间（天/周/月）内的完成数与总任务数
class CompletionBucket {
  const CompletionBucket({
    required this.label,
    required this.completed,
    required this.planned,
  });

  final String label;
  final int completed;
  final int planned;
}

/// 按统计范围把逐日完成/计划数聚合成柱状图分桶：
/// - week：周一~周日 7 桶（标签 周一~周日）
/// - month：周一起始的自然周（月初/月末不足 7 天的小周也独立成桶，
///   标签为日期范围如 "7/27-8/2"）
/// - year：1~12 月 12 桶（标签 "1月"~"12月"）
///
/// 分桶全走 AppClock 日历日运算（addCalendarDays/daysBetween），跨 DST
/// 转换日不漂移；窗口外的日期在逐日 map 中无键取 0，月视图跨月周
/// 天然只统计当月内日期，总数与卡片头部口径一致。
List<CompletionBucket> completionBuckets({
  required String range,
  required DateTime now,
  required Map<DateTime, int> completed,
  required Map<DateTime, int> planned,
}) {
  int dayValue(Map<DateTime, int> map, DateTime day) {
    final a = AppClock.asApp(day);
    return map[AppClock.at(a.year, a.month, a.day)] ?? 0;
  }

  int sumDays(Map<DateTime, int> map, DateTime from, int count) {
    var sum = 0;
    for (var i = 0; i < count; i++) {
      sum += dayValue(map, AppClock.addCalendarDays(from, i));
    }
    return sum;
  }

  final buckets = <CompletionBucket>[];
  switch (range) {
    case 'week':
      final monday = DateUtilsEx.mondayOf(now);
      for (var i = 0; i < 7; i++) {
        final day = AppClock.addCalendarDays(monday, i);
        buckets.add(CompletionBucket(
          label: DateUtilsEx.weekdayCn[i],
          completed: dayValue(completed, day),
          planned: dayValue(planned, day),
        ));
      }
    case 'month':
      final monthStart = AppClock.at(now.year, now.month, 1);
      final lastOfMonth = AppClock.at(
        now.year,
        now.month,
        DateUtilsEx.daysInMonth(monthStart),
      );
      var weekStart = DateUtilsEx.mondayOf(monthStart);
      while (AppClock.daysBetween(weekStart, lastOfMonth) >= 0) {
        final weekEnd = AppClock.addCalendarDays(weekStart, 6);
        buckets.add(CompletionBucket(
          label:
              '${weekStart.month}/${weekStart.day}-${weekEnd.month}/${weekEnd.day}',
          completed: sumDays(completed, weekStart, 7),
          planned: sumDays(planned, weekStart, 7),
        ));
        weekStart = AppClock.addCalendarDays(weekStart, 7);
      }
    case 'year':
      for (var m = 1; m <= 12; m++) {
        final monthStart = AppClock.at(now.year, m, 1);
        final days = DateUtilsEx.daysInMonth(monthStart);
        buckets.add(CompletionBucket(
          label: '$m月',
          completed: sumDays(completed, monthStart, days),
          planned: sumDays(planned, monthStart, days),
        ));
      }
  }
  return buckets;
}

class _CompletionCard extends StatelessWidget {
  const _CompletionCard({
    required this.completed,
    required this.planned,
    required this.range,
  });

  final Map<DateTime, int> completed;
  final Map<DateTime, int> planned;
  final String range;

  @override
  Widget build(BuildContext context) {
    final totalPlanned = planned.values.fold(0, (a, b) => a + b);
    final totalDone = completed.values.fold(0, (a, b) => a + b);
    // C7-1：完成率封顶 100%（补做上周遗留任务时完成数>计划数，
    // 此前可显示 160% 反直觉）
    final rate = totalPlanned == 0
        ? 0.0
        : (totalDone / totalPlanned).clamp(0.0, 1.0);
    // 分桶柱状图：周=7 天 / 月=自然周 / 年=12 月
    final buckets = completionBuckets(
      range: range,
      now: AppClock.now(),
      completed: completed,
      planned: planned,
    );
    final hasData = buckets.any((b) => b.planned > 0 || b.completed > 0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '完成率',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 4),
            // A6：百分比数字 count-up 动画
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: rate),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Text(
                '${(v * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            Text(
              '计划 $totalPlanned 项 · 完成 $totalDone 项',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              '说明：完成数与计划数均按任务所属日统计，无计划时间的任务与子任务不计入',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            if (!hasData)
              const Text('该时段无计划任务', style: TextStyle(color: Colors.grey))
            else
              _CompletionBarChart(buckets: buckets),
          ],
        ),
      ),
    );
  }
}

/// 单个分桶柱子的几何与标注（纯函数，便于单元测试）。
///
/// 渲染规则：
/// - planned > 0：浅色"总任务"柱满高（所有非空桶等高）；
///   深色"已完成"填充 = 满高 × min(1, 完成/计划)，completed > 0 时
///   至少 minFill（避免极小比例时填充不可见）；
/// - planned == 0 && completed > 0（补做遗留任务等）：无比例可算，
///   填充按满高渲染，柱顶 100%（与卡片头部 C7-1 完成率封顶一致）；
/// - planned == 0 && completed == 0：minBar 矮柱、无填充、柱顶 —。
class BarMetrics {
  const BarMetrics({
    required this.totalHeight,
    required this.fillHeight,
    required this.percent,
  });

  final double totalHeight;
  final double fillHeight; // 0 = 不渲染
  final String percent;
}

BarMetrics barMetrics(
  int planned,
  int completed, {
  double areaHeight = 100,
  double minBar = 2,
  double minFill = 2,
}) {
  final ratio = planned > 0 ? (completed / planned).clamp(0.0, 1.0) : 0.0;
  return BarMetrics(
    totalHeight: planned > 0 ? areaHeight : minBar,
    fillHeight: planned > 0
        ? (completed > 0
              ? (areaHeight * ratio).clamp(minFill, areaHeight)
              : 0.0)
        : (completed > 0 ? areaHeight : 0.0),
    percent: planned > 0
        ? '${(ratio * 100).round()}%'
        : (completed > 0 ? '100%' : '—'),
  );
}

/// 完成率卡片下的分桶柱状图（堆叠填充式）：
/// - 浅色柱 = 总任务数（计划数口径），planned > 0 的桶一律满高（等高）；
/// - 深色填充 = 完成数，高度 = 满高 × 完成/计划（封顶 100%，下限 2px 保证可见）；
/// - 柱顶百分比（无计划且无完成时显示 —）、柱下 完成数/总数 与桶标签。
class _CompletionBarChart extends StatelessWidget {
  const _CompletionBarChart({required this.buckets});

  final List<CompletionBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 各段固定高度：百分比 12 + 柱区 100 + 计数 14 + 标签 14 = 140
    const barAreaHeight = 100.0;
    const barWidth = 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 图例
        Row(
          children: [
            _LegendItem(color: scheme.primaryContainer, label: '总任务'),
            const SizedBox(width: 12),
            _LegendItem(color: scheme.primary, label: '已完成'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final b in buckets)
                Expanded(
                  child: _BucketBar(
                    bucket: b,
                    barAreaHeight: barAreaHeight,
                    barWidth: barWidth,
                    scheme: scheme,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单根柱子：柱顶百分比 + 浅色总任务柱（等高）+ 深色已完成填充（比例）
/// + 柱下 完成数/总数 图注 + 桶标签。
class _BucketBar extends StatelessWidget {
  const _BucketBar({
    required this.bucket,
    required this.barAreaHeight,
    required this.barWidth,
    required this.scheme,
  });

  final CompletionBucket bucket;
  final double barAreaHeight;
  final double barWidth;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final b = bucket;
    final m = barMetrics(b.planned, b.completed, areaHeight: barAreaHeight);
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          height: 12,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              m.percent,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: b.planned > 0 ? scheme.primary : Colors.grey.shade500,
              ),
            ),
          ),
        ),
        SizedBox(
          height: barAreaHeight,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              // 总任务柱（浅色，等高）
              Container(
                width: barWidth,
                height: m.totalHeight,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                ),
              ),
              // 已完成填充（深色，按 完成/计划 比例，下限 2px 保证可见）
              if (m.fillHeight > 0)
                Container(
                  width: barWidth,
                  height: m.fillHeight,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 14,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${b.completed}/${b.planned}',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
        ),
        SizedBox(
          height: 14,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              b.label,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}

class _PomodoroCard extends StatelessWidget {
  const _PomodoroCard({required this.days});

  final Map<DateTime, int> days;

  @override
  Widget build(BuildContext context) {
    final totalMinutes = days.values.fold(0, (a, b) => a + b);
    // 点击进入专注详情页（每日/每任务明细 + 周月年图表）
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PomodoroStatsPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '专注时长',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 4),
              // A6：专注时长数字 count-up 动画
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: totalMinutes / 60),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => Text(
                  '${v.toStringAsFixed(1)} 小时',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    '共 ${days.values.length} 天有专注记录',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    '查看详情',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HabitHeatmap extends StatelessWidget {
  const _HabitHeatmap({
    required this.habitName,
    required this.icon,
    required this.heat,
  });

  final String habitName;
  final String icon;
  final Map<DateTime, bool> heat;

  @override
  Widget build(BuildContext context) {
    final keys = heat.keys.toList()..sort();
    // 窗口起点与终点（终点即今天），用于标注起止日期
    final start = keys.first;
    final end = keys.last;
    final rangeText = start.year == end.year
        ? '${start.month}/${start.day} – ${end.month}/${end.day}'
        : '${start.year}/${start.month}/${start.day} – '
            '${end.year}/${end.month}/${end.day}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer,
                  child: Text(icon, style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$habitName · 打卡热力图',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '近 90 天（$rangeText）· 红圈 = 今天',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            // 高度自适应——15 列 × 6 行恰好容纳 90 天，按宽度计算
            // 格子尺寸与总行数；固定 90px 在手机宽度下会留约 63px
            // 空白（30 列时每格仅约 7px、3 行只占约 27px）
            LayoutBuilder(
              builder: (context, constraints) {
                const cols = 15;
                const spacing = 3.0;
                final cell =
                    (constraints.maxWidth - spacing * (cols - 1)) / cols;
                final rows = (keys.length / cols).ceil();
                final height = rows * cell + spacing * (rows - 1);
                return SizedBox(
                  height: height,
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: spacing,
                          crossAxisSpacing: spacing,
                        ),
                    itemCount: keys.length,
                    itemBuilder: (context, i) {
                      final done = heat[keys[i]] ?? false;
                      final isToday = DateUtilsEx.sameDay(
                        keys[i],
                        AppClock.now(),
                      );
                      return Container(
                        decoration: BoxDecoration(
                          color: done
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          shape: BoxShape.circle,
                          border: isToday
                              ? Border.all(
                                  color: Theme.of(context).colorScheme.error,
                                  width: 1.5,
                                )
                              : null,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _YearHeatmap extends ConsumerStatefulWidget {
  const _YearHeatmap({super.key, required this.db});

  final AppDatabase db;

  @override
  ConsumerState<_YearHeatmap> createState() => _YearHeatmapState();
}

class _YearHeatmapState extends ConsumerState<_YearHeatmap> {
  Map<DateTime, int>? _counts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_YearHeatmap old) {
    super.didUpdateWidget(old);
    if (old.db != widget.db) _load();
  }

  Future<void> _load() async {
    final now = AppClock.now();
    final from = AppClock.at(now.year, 1, 1);
    final to = AppClock.at(now.year, 12, 31);
    final counts = await widget.db.getCompletedCountByDay(from, to);
    if (mounted) setState(() => _counts = counts);
  }

  @override
  Widget build(BuildContext context) {
    final counts = _counts;
    if (counts == null) return const SizedBox.shrink();
    final now = AppClock.now();
    final maxCount = counts.values
        .fold<int>(0, (a, b) => b > a ? b : a)
        .clamp(1, 10)
        .toInt();
    // 只渲染「1/1 至今」的已过日历日（含今天）——不再为未来日期
    // 留透明占位格，消除底部大片留白；今天为最后一格（红圈标注）。
    // 用日历日差而非绝对时长差——DST 时区 ±1h 会让 inDays 截断
    final jan1 = AppClock.at(now.year, 1, 1);
    final dayOfYear =
        AppClock.daysBetween(jan1, AppClock.at(now.year, now.month, now.day)) +
        1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${now.year} 年完成热力图',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '1/1 – ${now.month}/${now.day} · 共 $dayOfYear 天',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '颜色越深表示该日完成越多 · 红圈 = 今天',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            // 高度自适应——26 列按宽度计算格子尺寸与总行数，
            // 完整显示 1/1 至今（固定高度会裁剪底部）
            LayoutBuilder(
              builder: (context, constraints) {
                const cols = 26;
                const spacing = 3.0;
                final cell =
                    (constraints.maxWidth - spacing * (cols - 1)) / cols;
                final rows = (dayOfYear / cols).ceil();
                final height = rows * cell + spacing * (rows - 1);
                return SizedBox(
                  height: height,
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: spacing,
                          crossAxisSpacing: spacing,
                        ),
                    itemCount: dayOfYear,
                    itemBuilder: (context, i) {
                      final day = AppClock.addCalendarDays(jan1, i);
                      final c =
                          counts[AppClock.at(day.year, day.month, day.day)] ??
                          0;
                      final level = c == 0
                          ? 0.0
                          : (c / maxCount).clamp(0.0, 1.0);
                      final isToday = i == dayOfYear - 1;
                      return Container(
                        decoration: BoxDecoration(
                          color: c == 0
                              ? Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest
                              : Color.lerp(
                                  Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                  Theme.of(context).colorScheme.primary,
                                  level,
                                ),
                          shape: BoxShape.circle,
                          border: isToday
                              ? Border.all(
                                  color: Theme.of(context).colorScheme.error,
                                  width: 1.5,
                                )
                              : null,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
