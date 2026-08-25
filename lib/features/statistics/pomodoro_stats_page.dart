import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
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

/// 明细聚合组：同日 × 同任务 的记录合并（不再逐条罗列每次会话）。
/// 多选删除的最小粒度 = 一个聚合组（删除其覆盖的全部记录）。
class _RecordGroup {
  _RecordGroup({
    required this.day,
    required this.taskId,
    required this.records,
    required this.title,
  });

  final DateTime day;
  final int? taskId;
  final List<PomodoroRecord> records;
  final String title;

  int get totalMinutes => records.fold(0, (a, r) => a + r.durationMinutes);

  /// 选中键：日 + 任务 唯一
  String get key => '${day.millisecondsSinceEpoch}|$taskId';
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
/// 总时长/次数/平均每日汇总、每日/每周/每月专注时长柱状图（全部档不显示）、
/// 按任务占比的环形图与排行，以及按「日 × 任务」聚合的明细列表
/// （长按进入多选可批量删除，带撤销）。
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
  List<_RecordGroup> _groups = [];
  Map<int, String> _taskTitles = {};
  int _dayCount = 1; // 平均每日的分母（区间日历天数）
  bool _loading = true;

  /// 多选删除选中态：_RecordGroup.key 集合；非空即进入选中模式
  /// （AppBar 切换为全选/删除/关闭）
  final Set<String> _selected = {};

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
    final titles = {for (final t in tasks) t.id: t.title};
    if (mounted && seq == _loadSeq) {
      setState(() {
        _records = visible;
        _taskTitles = titles;
        _groups = _buildGroups(visible, titles);
        _dayCount = dayCount;
        // 数据变化（删除/撤销等）后重载：清空选中，避免引用过期组
        _selected.clear();
        _loading = false;
      });
    }
  }

  String _titleOf(int? taskId) {
    if (taskId == null) return '自由专注';
    // 防御：正常路径外键保证记录指向存在任务；极端脏数据兜底
    return _taskTitles[taskId] ?? '已删除任务';
  }

  /// 按任务聚合分钟数（降序；前 4 名 + 「其他」，共 5 行）
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
    const top = 4;
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
        // 周一起始的自然周（与统计页完成率月视图同口径：月初/月末
        // 不足 7 天的小周独立成桶，标签如 "8/17-8/23"；跨月周求和只含
        // 窗口内日期——记录已按当月过滤，逐日 map 无窗口外键）
        final byDay = _sumByDay(_records);
        final monthStart = AppClock.at(now.year, now.month, 1);
        final lastOfMonth = AppClock.at(
          now.year,
          now.month,
          DateUtilsEx.daysInMonth(monthStart),
        );
        var weekStart = DateUtilsEx.mondayOf(monthStart);
        final buckets = <_BarBucket>[];
        while (AppClock.daysBetween(weekStart, lastOfMonth) >= 0) {
          final weekEnd = AppClock.addCalendarDays(weekStart, 6);
          var sum = 0;
          for (var i = 0; i < 7; i++) {
            sum += byDay[AppClock.addCalendarDays(weekStart, i)] ?? 0;
          }
          buckets.add(
            _BarBucket(
              label:
                  '${weekStart.month}/${weekStart.day}-${weekEnd.month}/${weekEnd.day}',
              minutes: sum,
              showLabel: true,
            ),
          );
          weekStart = AppClock.addCalendarDays(weekStart, 7);
        }
        return buckets;
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

  /// 明细聚合：按「日 × 任务」分组（记录已按 completedAt 倒序）。
  /// 同一天同一任务的多次会话合并为一组（次数 + 合计时长），
  /// 不再逐条罗列每次会话。
  List<_RecordGroup> _buildGroups(
    List<PomodoroRecord> records,
    Map<int, String> titles,
  ) {
    String titleOf(int? taskId) {
      if (taskId == null) return '自由专注';
      return titles[taskId] ?? '已删除任务';
    }

    final groups = <String, _RecordGroup>{};
    for (final r in records) {
      final a = AppClock.asApp(r.completedAt);
      final d = AppClock.at(a.year, a.month, a.day);
      final key = '${d.millisecondsSinceEpoch}|${r.taskId}';
      final g = groups[key] ??
          _RecordGroup(day: d, taskId: r.taskId, records: [], title: titleOf(r.taskId));
      g.records.add(r);
      groups[key] = g;
    }
    final list = groups.values.toList()
      // 日降序（同日记录已倒序），组内再按时长降序
      ..sort((a, b) {
        final byDay = b.day.compareTo(a.day);
        return byDay != 0 ? byDay : b.totalMinutes.compareTo(a.totalMinutes);
      });
    return list;
  }

  // ---------- 多选删除 ----------

  bool get _selecting => _selected.isNotEmpty;

  /// 长按/点选：切换某聚合组选中态（进入选中模式）
  void _toggleGroup(_RecordGroup g) {
    setState(() {
      if (!_selected.remove(g.key)) _selected.add(g.key);
    });
  }

  /// 全选 / 取消全选（以当前区间全部聚合组为全集）
  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _groups.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_groups.map((g) => g.key));
      }
    });
  }

  void _exitSelection() => setState(_selected.clear);

  /// 选中组覆盖的全部记录
  List<PomodoroRecord> _selectedRecords() => [
    for (final g in _groups)
      if (_selected.contains(g.key)) ...g.records,
  ];

  Future<void> _confirmDeleteSelected() async {
    final records = _selectedRecords();
    final count = records.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除所选专注记录？'),
        content: Text('将删除 $count 条专注记录，删除后可撤销'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(c).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _exitSelection();
    final db = ref.read(dbProvider);
    await db.deletePomodoroByIds(records.map((r) => r.id).toList());
    // 删除后刷新本页与统计页
    ref.read(dataVersionProvider.notifier).state++;
    if (!mounted) return;
    showAppSnackBar(
      context,
      '已删除 $count 条专注记录',
      actionLabel: '撤销',
      onAction: () async {
        // 按原 id 恢复（insertOrReplace）；再次 bump 触发刷新
        for (final r in records) {
          await db.insertPomodoroRaw(r.toCompanion(false));
        }
        ref.read(dataVersionProvider.notifier).state++;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 选中模式：AppBar 切换为 已选 N 项 + 全选/删除/关闭
    final selecting = _selecting;
    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '已选 ${_selected.length} 项' : '专注详情'),
        actions: [
          if (selecting) ...[
            IconButton(
              icon: Icon(
                _selected.length == _groups.length
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              tooltip: '全选',
              onPressed: _toggleSelectAll,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除所选',
              onPressed: _confirmDeleteSelected,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消',
              onPressed: _exitSelection,
            ),
          ],
        ],
      ),
      // 档位选择器移出 AppBar（与统计主页一致），固定在内容区顶部
      body: Column(
        children: [
          if (!selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'week', label: Text('周')),
                  ButtonSegment(value: 'month', label: Text('月')),
                  ButtonSegment(value: 'year', label: Text('年')),
                  ButtonSegment(value: 'all', label: Text('全部')),
                ],
                selected: {_range},
                onSelectionChanged: (s) {
                  if (s.first == _range) return;
                  // 切档保留旧内容就地刷新，避免整页白闪
                  setState(() => _range = s.first);
                  _load();
                },
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          Expanded(
            child: _loading
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
                // 全部档不显示柱状图（历史跨度大，月柱信息价值低）
                if (_range != 'all') ...[
                  const SizedBox(height: 16),
                  _BarChartCard(
                    title: switch (_range) {
                      'week' => '每日专注时长',
                      'month' => '每周专注时长',
                      _ => '每月专注时长',
                    },
                    // 各档固定柱宽：周 7 根、月 ≤6 周桶、年 12 根
                    barWidth: switch (_range) {
                      'week' => 20,
                      'month' => 26,
                      _ => 16,
                    },
                    buckets: _buildBuckets(AppClock.now()),
                  ),
                ],
                const SizedBox(height: 16),
                _TaskDistributionCard(slices: _buildTaskSlices()),
                const SizedBox(height: 16),
                _RecordListCard(
                  groups: _groups,
                  selected: _selected,
                  selecting: selecting,
                  onToggle: _toggleGroup,
                  onLongPress: _toggleGroup,
                ),
              ],
            ),
          ),
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
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            const Text(
              '还没有专注记录',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '去"我的 > 番茄专注"开始第一次专注',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
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

/// 专注时长柱状图卡片（每日/每周/每月随档位变化，柱宽按档位固定）
class _BarChartCard extends StatelessWidget {
  const _BarChartCard({
    required this.title,
    required this.buckets,
    required this.barWidth,
  });

  final String title;
  final List<_BarBucket> buckets;
  final double barWidth;

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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _FocusBarChart(buckets: buckets, barWidth: barWidth),
          ],
        ),
      ),
    );
  }
}

/// 纯 Container 柱状图（延续统计页无图表库的手绘风格）。
///
/// - 柱宽按档位固定（[barWidth]），单元格由 Expanded 均分整行宽度，
///   柱在单元格内水平居中——行宽恒定、任何屏宽/字号都不会横向溢出，
///   相邻柱间距随屏宽自适应。
/// - 柱高按相对值：区间最大值满高，其余按 minutes/maxV 等比缩放。
/// - 柱顶数值固定在 16px 槽内（FittedBox 缩放 + maxLines:1）：窄柱
///   （如年档 12 根）下文本不换行、不撑高溢出。
/// - 标签行与柱区同为等宽 Expanded 单元格，柱与标签严格对齐。
class _FocusBarChart extends StatelessWidget {
  const _FocusBarChart({required this.buckets, required this.barWidth});

  final List<_BarBucket> buckets;
  final double barWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxV = buckets
        .fold<int>(0, (a, b) => math.max(a, b.minutes))
        .clamp(1, 0x7fffffff)
        .toInt();
    const chartHeight = 110.0;
    // 柱顶数值固定 16px 槽（FittedBox 缩放）：窄柱下文本不换行
    const valueSlot = 16.0;
    final showValues = buckets.length <= 12;
    final labelStyle = TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Column(
      children: [
        SizedBox(
          height: chartHeight + valueSlot + 2,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final b in buckets)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        height: valueSlot,
                        child: showValues && b.minutes > 0
                            ? FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _shortFocusMinutes(b.minutes),
                                  maxLines: 1,
                                  style: labelStyle,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 2),
                      // 固定柱宽、单元格内居中；高度按相对值（最大值满高），
                      // 隐式过渡让切档/数据刷新时柱高平滑变形
                      Center(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(
                            begin: 0,
                            end: (b.minutes / maxV * chartHeight)
                                .clamp(0.0, chartHeight)
                                .toDouble(),
                          ),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          builder: (context, h, _) => Container(
                            width: barWidth,
                            height: h,
                            decoration: BoxDecoration(
                              color: b.minutes > 0
                                  ? cs.primary
                                  : cs.surfaceContainerHighest,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // 标签与柱区同为等宽 Expanded；FittedBox 缩放避免窄屏截断
        //（对齐统计页完成率柱状图标签的做法）
        Row(
          children: [
            for (final b in buckets)
              Expanded(
                child: SizedBox(
                  height: 14,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      b.showLabel ? b.label : '',
                      maxLines: 1,
                      style: labelStyle,
                    ),
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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (total == 0)
              Text('该时段无专注记录', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
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
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
              // 时长可压缩缩放：极窄屏下不把图例行挤溢出
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatFocusMinutes(slice.minutes),
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 36,
                child: Text(
                  '${(fraction * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
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

/// 记录明细卡：按「日 × 任务」聚合分组（日期头 + 当日合计 + 每任务
/// 一行：N 次 / 合计时长）。长按或选中态点击进入多选删除。
class _RecordListCard extends StatelessWidget {
  const _RecordListCard({
    required this.groups,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    required this.onLongPress,
  });

  final List<_RecordGroup> groups;
  final Set<String> selected;
  final bool selecting;
  final void Function(_RecordGroup) onToggle;
  final void Function(_RecordGroup) onLongPress;

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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            if (groups.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('该时段无专注记录', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            else
              for (var i = 0; i < groups.length; i++) ...[
                if (i == 0 || !DateUtilsEx.sameDay(groups[i - 1].day, groups[i].day))
                  // 日分组头（同日仅一个，跨日才渲染）
                  _DayHeader(
                    day: groups[i].day,
                    total: _dayTotal(groups, groups[i].day),
                  ),
                _RecordGroupTile(
                  group: groups[i],
                  selected: selected.contains(groups[i].key),
                  selecting: selecting,
                  onTap: selecting ? () => onToggle(groups[i]) : null,
                  onLongPress: () => onLongPress(groups[i]),
                ),
              ],
          ],
        ),
      ),
    );
  }

  int _dayTotal(List<_RecordGroup> groups, DateTime day) {
    var sum = 0;
    for (final g in groups) {
      if (!DateUtilsEx.sameDay(g.day, day)) continue;
      sum += g.totalMinutes;
    }
    return sum;
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
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 聚合组行：任务名 + N 次 + 合计时长；长按进入多选、选中态点击切换勾选
class _RecordGroupTile extends StatelessWidget {
  const _RecordGroupTile({
    required this.group,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final _RecordGroup group;
  final bool selected;
  final bool selecting;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final linked = group.taskId != null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected,
      // 选中态显示勾选框（与任务页多选一致）；非选中态显示任务/自由图标
      leading: selecting
          ? Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : Icon(
              linked ? Icons.check_circle_outline : Icons.timer_outlined,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      title: Text(
        group.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        '${group.records.length} 次',
        style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      trailing: Text(
        formatFocusMinutes(group.totalMinutes),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
