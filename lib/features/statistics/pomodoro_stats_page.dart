import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';

/// 分钟 → 中文时长文案：`45 分钟` / `1小时` / `1小时30分` / `2小时`
String formatFocusMinutes(int minutes) {
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h小时' : '$h小时$m分';
}

/// 短时长（柱状图柱顶标注，空间有限用缩写）：`45分` / `1.5时`
String _shortFocusMinutes(int minutes) {
  if (minutes < 60) return '$minutes分';
  return '${(minutes / 60).toStringAsFixed(1)}时';
}

/// 柱状图数据桶：横轴标签 + 该桶分钟数
class _BarBucket {
  const _BarBucket({
    required this.label,
    required this.minutes,
    required this.showLabel,
  });

  final String label;
  final int minutes;
  final bool showLabel;
}

/// 任务分布切片：任务名 + 分钟数 + 配色
class _TaskSlice {
  const _TaskSlice({
    required this.label,
    required this.minutes,
    required this.color,
  });

  final String label;
  final int minutes;
  final Color color;
}

/// 环形图固定配色（明暗主题均可区分，前 6 + 「其他」循环取用）
const _slicePalette = <Color>[
  Color(0xFFE57373),
  Color(0xFF64B5F6),
  Color(0xFF81C784),
  Color(0xFFFFB74D),
  Color(0xFFBA68C8),
  Color(0xFF4DD0E1),
  Color(0xFFDCE775),
];

/// 番茄专注详情页。
///
/// 从统计页「专注时长」卡片进入：展示选中区间（周/月/年/全部）的
/// 总时长/次数/平均每日汇总、每日或每月专注时长柱状图、按任务占比的
/// 环形图与排行，以及「几月几号在什么任务上专注了几时几分」的明细列表。
///
/// 数据口径与统计页一致：completedAt 按应用时区归日/归月（[AppClock.asApp]）；
/// `durationMinutes == 0` 的立即结束记录不计次数、不进明细（对求和天然无影响）。
class PomodoroStatsPage extends ConsumerStatefulWidget {
  const PomodoroStatsPage({super.key});

  @override
  ConsumerState<PomodoroStatsPage> createState() => _PomodoroStatsPageState();
}

class _PomodoroStatsPageState extends ConsumerState<PomodoroStatsPage> {
  String _range = 'month'; // week / month / year / all
  List<PomodoroRecord> _records = [];
  Map<int, String> _taskTitles = {};
  int _dayCount = 1; // 平均每日的分母（区间日历天数）
  bool _loading = true;

  /// _load 请求序号——丢弃过期结果（快速切换周/月/年/全部时
  /// 旧请求不得覆盖新选择）
  int _loadSeq = 0;
  late final ProviderSubscription<int> _dataSub;

  @override
  void initState() {
    super.initState();
    // 番茄记录写库（dataVersionProvider++）后自动刷新
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

  /// 区间边界（含两端；'all' 返回 null 表示不限窗口）
  (DateTime?, DateTime?) _bounds(DateTime now) {
    switch (_range) {
      case 'week':
        final from = DateUtilsEx.mondayOf(now);
        return (from, AppClock.addCalendarDays(from, 6));
      case 'month':
        final from = AppClock.at(now.year, now.month, 1);
        return (from, AppClock.at(now.year, now.month + 1, 0));
      case 'year':
        final from = AppClock.at(now.year, 1, 1);
        return (from, AppClock.at(now.year, 12, 31));
      default:
        return (null, null);
    }
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final db = ref.read(dbProvider);
    final now = AppClock.now();
    final (from, to) = _bounds(now);
    final records = await db.getPomodoros(from: from, to: to);
    final tasks = await db.getAllTasks();
    // 立即结束产生的 0 分钟记录：不计次数、不进明细/图表求和天然为 0
    final visible = [
      for (final r in records)
        if (r.durationMinutes > 0) r,
    ];
    int dayCount;
    if (from == null) {
      // 'all'：分母 = 首条记录日到今天的日历天数（至少 1）
      if (visible.isEmpty) {
        dayCount = 1;
      } else {
        // getPomodoros 按 completedAt 倒序 → 末条即最早记录
        final first = AppClock.asApp(visible.last.completedAt);
        dayCount = math.max(1, AppClock.daysBetween(first, now) + 1);
      }
    } else {
      // from 非空时 to 必非空（_bounds 成对返回）
      dayCount = AppClock.daysBetween(from, to!) + 1;
    }
    if (mounted && seq == _loadSeq) {
      setState(() {
        _records = visible;
        _taskTitles = {for (final t in tasks) t.id: t.title};
        _dayCount = dayCount;
        _loading = false;
      });
    }
  }

  String _titleOf(int? taskId) {
    if (taskId == null) return '自由专注';
    // 防御：正常路径外键保证记录指向存在任务；极端脏数据兜底
    return _taskTitles[taskId] ?? '已删除任务';
  }

  /// 按任务聚合分钟数（降序；前 6 名 + 「其他」）
  List<_TaskSlice> _buildTaskSlices() {
    final byLabel = <String, int>{};
    for (final r in _records) {
      final label = _titleOf(r.taskId);
      byLabel[label] = (byLabel[label] ?? 0) + r.durationMinutes;
    }
    if (byLabel.isEmpty) return const [];
    final sorted = byLabel.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final slices = <_TaskSlice>[];
    const top = 6;
    for (var i = 0; i < sorted.length && i < top; i++) {
      slices.add(
        _TaskSlice(
          label: sorted[i].key,
          minutes: sorted[i].value,
          color: _slicePalette[i % _slicePalette.length],
        ),
      );
    }
    if (sorted.length > top) {
      final rest = sorted.skip(top).fold<int>(0, (a, e) => a + e.value);
      slices.add(
        _TaskSlice(
          label: '其他',
          minutes: rest,
          color: _slicePalette[top % _slicePalette.length],
        ),
      );
    }
    return slices;
  }

  Map<DateTime, int> _sumByDay(List<PomodoroRecord> records) {
    final map = <DateTime, int>{};
    for (final r in records) {
      final a = AppClock.asApp(r.completedAt);
      final d = AppClock.at(a.year, a.month, a.day);
      map[d] = (map[d] ?? 0) + r.durationMinutes;
    }
    return map;
  }

  /// key 为 '年-月'（如 '2026-8'），用于年/全部档按月聚合
  Map<String, int> _sumByMonth(List<PomodoroRecord> records) {
    final map = <String, int>{};
    for (final r in records) {
      final a = AppClock.asApp(r.completedAt);
      final key = '${a.year}-${a.month}';
      map[key] = (map[key] ?? 0) + r.durationMinutes;
    }
    return map;
  }

  /// 按当前档位构建柱状图数据
  List<_BarBucket> _buildBuckets(DateTime now) {
    switch (_range) {
      case 'week':
        final from = DateUtilsEx.mondayOf(now);
        final byDay = _sumByDay(_records);
        return [
          for (var i = 0; i < 7; i++)
            _BarBucket(
              label: DateUtilsEx.weekdayCn[i],
              minutes: byDay[AppClock.addCalendarDays(from, i)] ?? 0,
              showLabel: true,
            ),
        ];
      case 'month':
        final days = DateUtilsEx.daysInMonth(now);
        final byDay = _sumByDay(_records);
        return [
          for (var d = 1; d <= days; d++)
            _BarBucket(
              label: '$d',
              minutes: byDay[AppClock.at(now.year, now.month, d)] ?? 0,
              // 稀疏标注避免 31 根柱标签拥挤
              showLabel: d == 1 || d % 5 == 0 || d == days,
            ),
        ];
      case 'year':
        final byMonth = _sumByMonth(_records);
        return [
          for (var m = 1; m <= 12; m++)
            _BarBucket(
              label: '$m月',
              minutes: byMonth['${now.year}-$m'] ?? 0,
              showLabel: true,
            ),
        ];
      default:
        // 'all'：从首条记录所在月到当前月，按月聚合
        final byMonth = _sumByMonth(_records);
        DateTime startMonth;
        if (_records.isNotEmpty) {
          final oldest = AppClock.asApp(_records.last.completedAt);
          startMonth = AppClock.at(oldest.year, oldest.month, 1);
        } else {
          startMonth = AppClock.at(now.year, now.month, 1);
        }
        final endMonth = AppClock.at(now.year, now.month, 1);
        final total =
            (endMonth.year * 12 + endMonth.month) -
            (startMonth.year * 12 + startMonth.month) +
            1;
        final step = math.max(1, (total / 12).ceil());
        final buckets = <_BarBucket>[];
        var y = startMonth.year;
        var mo = startMonth.month;
        for (var i = 0; i < total; i++) {
          final key = '$y-$mo';
          buckets.add(
            _BarBucket(
              label: y == now.year ? '$mo月' : '$y/$mo',
              minutes: byMonth[key] ?? 0,
              showLabel: i % step == 0 || i == total - 1,
            ),
          );
          mo++;
          if (mo > 12) {
            mo = 1;
            y++;
          }
        }
        return buckets;
    }
  }

  /// 明细按日分组（记录已按 completedAt 倒序，组内同样倒序）
  Map<DateTime, List<PomodoroRecord>> _groupByDay() {
    final groups = <DateTime, List<PomodoroRecord>>{};
    for (final r in _records) {
      final a = AppClock.asApp(r.completedAt);
      final d = AppClock.at(a.year, a.month, a.day);
      groups.putIfAbsent(d, () => []).add(r);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('专注详情'),
        actions: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'week', label: Text('周')),
              ButtonSegment(value: 'month', label: Text('月')),
              ButtonSegment(value: 'year', label: Text('年')),
              ButtonSegment(value: 'all', label: Text('全部')),
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
          : _records.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [_EmptyCard()],
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SummaryRow(
                  totalMinutes: _records.fold<int>(
                    0,
                    (a, r) => a + r.durationMinutes,
                  ),
                  count: _records.length,
                  dayCount: _dayCount,
                ),
                const SizedBox(height: 16),
                _BarChartCard(
                  title: _range == 'year' || _range == 'all' ? '每月专注时长' : '每日专注时长',
                  buckets: _buildBuckets(AppClock.now()),
                ),
                const SizedBox(height: 16),
                _TaskDistributionCard(slices: _buildTaskSlices()),
                const SizedBox(height: 16),
                _RecordListCard(groups: _groupByDay(), titles: _titleOf),
              ],
            ),
    );
  }
}

/// 空态（区间内没有任何有效专注记录）
class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Column(
          children: [
            Icon(
              Icons.timer_off_outlined,
              size: 48,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            const Text(
              '还没有专注记录',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '去"我的 > 番茄专注"开始第一次专注',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 汇总三卡：总时长 / 专注次数 / 平均每天
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.totalMinutes,
    required this.count,
    required this.dayCount,
  });

  final int totalMinutes;
  final int count;
  final int dayCount;

  @override
  Widget build(BuildContext context) {
    final avg = dayCount <= 0 ? 0 : (totalMinutes / dayCount).round();
    return Row(
      children: [
        Expanded(
          child: _SummaryTile(label: '总时长', value: formatFocusMinutes(totalMinutes)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SummaryTile(label: '专注次数', value: '$count 次'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SummaryTile(label: '平均每天', value: formatFocusMinutes(avg)),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 专注时长柱状图卡片（每日/每月随档位变化）
class _BarChartCard extends StatelessWidget {
  const _BarChartCard({required this.title, required this.buckets});

  final String title;
  final List<_BarBucket> buckets;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 12),
            _FocusBarChart(buckets: buckets),
          ],
        ),
      ),
    );
  }
}

/// 纯 Container 柱状图（延续统计页无图表库的手绘风格）
class _FocusBarChart extends StatelessWidget {
  const _FocusBarChart({required this.buckets});

  final List<_BarBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxV = buckets
        .fold<int>(0, (a, b) => math.max(a, b.minutes))
        .clamp(1, 0x7fffffff)
        .toInt();
    const chartHeight = 110.0;
    // 桶少（周/年/全部月柱）时柱顶显示时长；桶多（月档每日柱）时不显示
    // 避免 31 根柱的数值文字互相重叠
    final showValues = buckets.length <= 12;
    return Column(
      children: [
        SizedBox(
          height: chartHeight + (showValues ? 18 : 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final b in buckets)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (showValues && b.minutes > 0)
                          Text(
                            _shortFocusMinutes(b.minutes),
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        const SizedBox(height: 2),
                        Container(
                          height: (b.minutes / maxV * chartHeight)
                              .clamp(0.0, chartHeight)
                              .toDouble(),
                          decoration: BoxDecoration(
                            color: b.minutes > 0
                                ? cs.primary
                                : cs.surfaceContainerHighest,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final b in buckets)
              Expanded(
                child: Text(
                  b.showLabel ? b.label : '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// 任务分布卡：环形图 + 图例/排行（横向条形）
class _TaskDistributionCard extends StatelessWidget {
  const _TaskDistributionCard({required this.slices});

  final List<_TaskSlice> slices;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<int>(0, (a, s) => a + s.minutes);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '任务分布',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 16),
            if (total == 0)
              const Text('该时段无专注记录', style: TextStyle(color: Colors.grey))
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 环形图
                  SizedBox(
                    width: 132,
                    height: 132,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(painter: _DonutPainter(slices: slices)),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                formatFocusMinutes(total),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '总时长',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // 图例 + 排行
                  Expanded(
                    child: Column(
                      children: [
                        for (final s in slices) _SliceLegendRow(slice: s, total: total),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 环形图绘制：按分钟数占比画扇区（描边圆环）
class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.slices});

  final List<_TaskSlice> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<int>(0, (a, s) => a + s.minutes);
    if (total <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 6;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const strokeWidth = 20.0;
    var start = -math.pi / 2;
    for (final s in slices) {
      final sweep = s.minutes / total * 2 * math.pi;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = s.color;
      // 扇区足够大时留 0.03rad 细缝，视觉上区分相邻切片
      canvas.drawArc(
        rect,
        start,
        sweep > 0.04 ? sweep - 0.03 : sweep,
        false,
        paint,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.slices != slices;
}

/// 图例行：色点 + 任务名 + 时长/占比 + 占比条形
class _SliceLegendRow extends StatelessWidget {
  const _SliceLegendRow({required this.slice, required this.total});

  final _TaskSlice slice;
  final int total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fraction = total == 0 ? 0.0 : (slice.minutes / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: slice.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  slice.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Text(
                formatFocusMinutes(slice.minutes),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 36,
                child: Text(
                  '${(fraction * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 5,
              color: slice.color,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// 记录明细卡：按日分组（日期 + 当日合计 + 每条任务/时段/时长）
class _RecordListCard extends StatelessWidget {
  const _RecordListCard({required this.groups, required this.titles});

  final Map<DateTime, List<PomodoroRecord>> groups;
  final String Function(int?) titles;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '记录明细',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 4),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('该时段无专注记录', style: TextStyle(color: Colors.grey)),
              )
            else
              for (final g in groups.entries) ...[
                _DayHeader(
                  day: g.key,
                  total: g.value.fold<int>(0, (a, r) => a + r.durationMinutes),
                ),
                for (final r in g.value) _RecordTile(record: r, title: titles(r.taskId)),
              ],
          ],
        ),
      ),
    );
  }
}

/// 日分组头：日期 + 当日合计
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.total});

  final DateTime day;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Row(
        children: [
          Text(
            DateUtilsEx.dateCn(day),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const Spacer(),
          Text(
            '共 ${formatFocusMinutes(total)}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}

/// 单条记录：任务名 + 起止时间段 + 时长
class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record, required this.title});

  final PomodoroRecord record;
  final String title;

  @override
  Widget build(BuildContext context) {
    final linked = record.taskId != null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        linked ? Icons.check_circle_outline : Icons.timer_outlined,
        size: 20,
        color: Colors.grey.shade500,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        '${DateUtilsEx.timeCn(record.startedAt)}–${DateUtilsEx.timeCn(record.completedAt)}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
      ),
      trailing: Text(
        formatFocusMinutes(record.durationMinutes),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
