import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

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
        to = from.add(const Duration(days: 6));
        break;
      case 'month':
        from = DateTime(now.year, now.month, 1);
        to = DateTime(now.year, now.month + 1, 0);
        break;
      case 'year':
        from = DateTime(now.year, 1, 1);
        to = DateTime(now.year, 12, 31);
        break;
      default:
        from = DateTime(now.year, now.month, 1);
        to = DateTime(now.year, now.month + 1, 0);
    }
    final completed = await db.getCompletedCountByDay(from, to);
    final planned = await db.getPlannedCountByDay(from, to);
    final pomodoros = await db.getPomodoros(from: from, to: to);

    // F1：习惯热力图（每个习惯独立）
    final habits = await db.getHabits();
    final habitStart = now.subtract(const Duration(days: 89));
    final heatByHabit = <int, Map<DateTime, bool>>{};
    for (final h in habits) {
      final map = <DateTime, bool>{};
      for (var d = 0; d < 90; d++) {
        final day = habitStart.add(Duration(days: d));
        map[DateTime(day.year, day.month, day.day)] = false;
      }
      heatByHabit[h.id] = map;
    }
    final records = await db.getAllHabitRecords();
    for (final r in records) {
      final day = DateTime(r.date.year, r.date.month, r.date.day);
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
      final d = DateTime(
        r.completedAt.year,
        r.completedAt.month,
        r.completedAt.day,
      );
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
                _CompletionCard(completed: _completed, planned: _planned),
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
                _YearHeatmap(
                  key: ValueKey(_loadSeq),
                  db: ref.read(dbProvider),
                ),
              ],
            ),
    );
  }
}

class _CompletionCard extends StatelessWidget {
  const _CompletionCard({required this.completed, required this.planned});

  final Map<DateTime, int> completed;
  final Map<DateTime, int> planned;

  @override
  Widget build(BuildContext context) {
    final totalPlanned = planned.values.fold(0, (a, b) => a + b);
    final totalDone = completed.values.fold(0, (a, b) => a + b);
    // C7-1：完成率封顶 100%（补做上周遗留任务时完成数>计划数，
    // 此前可显示 160% 反直觉）
    final rate = totalPlanned == 0
        ? 0.0
        : (totalDone / totalPlanned).clamp(0.0, 1.0);
    // 每日条形图
    final days = planned.keys.toList()..sort();
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
              '说明：完成数按完成时间统计、计划数按计划日统计（子任务不计入）',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
            ),
            const SizedBox(height: 12),
            if (days.isEmpty)
              const Text('该时段无计划任务', style: TextStyle(color: Colors.grey))
            else
              SizedBox(
                height: 80,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in days)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // C7-1：完成条按"完成/计划"比例填充在计划条内
                              // （此前固定 14px 独立条，视觉与数字不等比）
                              SizedBox(
                                height: 20,
                                child: Stack(
                                  alignment: Alignment.bottomCenter,
                                  children: [
                                    Container(
                                      width: 10,
                                      height: ((planned[d] ?? 0)
                                          .clamp(1, 20)
                                          .toDouble()),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        borderRadius: const BorderRadius.vertical(
                                          top: Radius.circular(2),
                                        ),
                                      ),
                                    ),
                                    if ((planned[d] ?? 0) > 0)
                                      Container(
                                        width: 4,
                                        height: ((planned[d] ?? 0)
                                                    .clamp(1, 20)
                                                    .toDouble()) *
                                            ((completed[d] ?? 0) /
                                                    (planned[d] ?? 0))
                                                .clamp(0.0, 1.0),
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PomodoroCard extends StatelessWidget {
  const _PomodoroCard({required this.days});

  final Map<DateTime, int> days;

  @override
  Widget build(BuildContext context) {
    final totalMinutes = days.values.fold(0, (a, b) => a + b);
    return Card(
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
            Text(
              '共 ${days.values.length} 天有专注记录',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$icon $habitName',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 90,
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 30,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                ),
                itemCount: keys.length,
                itemBuilder: (context, i) {
                  final done = heat[keys[i]] ?? false;
                  final isToday = DateUtilsEx.sameDay(keys[i], AppClock.now());
                  return Container(
                    decoration: BoxDecoration(
                      color: done
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                      border: isToday
                          ? Border.all(color: Theme.of(context).colorScheme.error, width: 1.5)
                          : null,
                    ),
                  );
                },
              ),
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
    final from = DateTime(now.year, 1, 1);
    final to = DateTime(now.year, 12, 31);
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
    // 闰年 366 天（此前固定 365 格漏掉 12/31）
    final daysInYear = DateTime(now.year + 1, 1, 1).difference(
      DateTime(now.year, 1, 1),
    ).inDays;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${now.year} 年完成热力图（GitHub 风格）',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '说明：颜色越深表示当天完成的任务越多',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
            ),
            const SizedBox(height: 12),
            // 高度自适应——26 列下全年 365/366 天需 14~15 行，
            // 固定 100px 只装得下约一半（8 月起底部被裁剪不可见）；
            // 按宽度计算格子尺寸与总行数，完整显示全年
            LayoutBuilder(
              builder: (context, constraints) {
                const cols = 26;
                const spacing = 3.0;
                final cell = (constraints.maxWidth - spacing * (cols - 1)) /
                    cols;
                final rows = (daysInYear / cols).ceil();
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
                    itemCount: daysInYear,
                    itemBuilder: (context, i) {
                      final day =
                          DateTime(now.year, 1, 1).add(Duration(days: i));
                      if (day.isAfter(now)) {
                        return Container(color: Colors.transparent);
                      }
                      final c = counts[DateTime(
                            day.year,
                            day.month,
                            day.day,
                          )] ??
                          0;
                      final level = c == 0
                          ? 0.0
                          : (c / maxCount).clamp(0.0, 1.0);
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
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                  level,
                                ),
                          shape: BoxShape.circle,
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
