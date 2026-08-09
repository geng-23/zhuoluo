import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';
import 'package:zhuoluo/features/calendar/views.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 日历页（E12：视图切换/月份选择/今天/添加收进左侧侧边栏）
/// 丝滑交互：左右边缘 24dp 区域滑动切换底部 tab（左缘右滑 → 上一个，
/// 右缘左滑 → 下一个），中间区域滑动翻月/翻周/翻日。
/// 实现：body 视图右缘收窄 rightEdge（左缘 0——时间栏贴屏幕左边），
/// 左右边缘为独立手势区——与 PageView 零手势竞争，
/// 任务块点击/长按/拖动不受影响（拖动边缘翻周由 Draggable 全局坐标驱动）。
class CalendarPage extends ConsumerWidget {
  const CalendarPage({
    super.key,
    this.onNavigateLeft,
    this.onNavigateRight,
  });

  /// 屏幕左边缘向右滑（切到上一个 tab，如任务）
  final VoidCallback? onNavigateLeft;
  /// 屏幕右边缘向左滑（切到下一个 tab，如四象限）
  final VoidCallback? onNavigateRight;

  /// 左边缘手势区宽度（dp）：覆盖时间栏区域（时间栏无交互元素），
  /// 视图左侧不收窄——时间栏贴屏幕左缘
  static const double leftEdgeWidth = 44;
  /// 右边缘手势区宽度（dp）：视图右缘收窄让位
  static const double rightEdgeWidth = 40;

  static final GlobalKey<ScaffoldState> scaffoldKey =
      GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(calendarControllerProvider);
    final notifier = ref.read(calendarControllerProvider.notifier);
    return Scaffold(
      key: scaffoldKey,
      // 丝滑交互：禁用抽屉边缘拖拽——右缘滑动让位给"切下一个 tab"手势
      //（抽屉仍可通过 AppBar 菜单按钮打开）
      drawerEdgeDragWidth: 0,
      appBar: AppBar(
        title: InkWell(
          onTap: () => _pickDate(context, notifier, state),
          child: Text(_titleFor(state)),
        ),
        actions: [
          // "今天"按钮移到顶部
          TextButton(onPressed: notifier.goToToday, child: const Text('今天')),
          IconButton(
            icon: const Icon(Icons.menu),
            tooltip: '日历菜单',
            onPressed: () => scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      ),
      endDrawer: _CalendarDrawer(
        state: state,
        onViewChanged: (v) => notifier.setView(v),
        onAdd: () => _openQuickAdd(context, ref),
        onPickDate: (d) => notifier.setSelectedDay(d),
      ),
      body: Stack(
        children: [
          // 中间视图（右缘收窄让位给手势区；左缘 0——时间栏贴屏幕左边）
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(right: rightEdgeWidth),
              child: Column(
                children: [
                  Expanded(
                    // 修复：仅首次（无数据）显示 spinner；后续 load（改期/勾选/翻页）
                    // 不整页替换——否则视图 State 销毁、滚动位置/翻页位置全部重置
                    child: (state.loading && state.items.isEmpty)
                        ? const Center(child: CircularProgressIndicator())
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, anim) =>
                                FadeTransition(opacity: anim, child: child),
                            child: switch (state.view) {
                              'month' => MonthPager(
                        key: const ValueKey('view-month'),
                        items: state.items,
                        byDay: state.byDay,
                        displayedMonth: state.displayedMonth,
                        selectedDay: state.selectedDay,
                        onMonthChanged: (m) => notifier.setDisplayedMonth(m),
                        onDayTap: (d) {
                          notifier.setSelectedDay(d);
                          // E1：#7.1 单击日期弹出当天任务弹层
                          _openDayPreview(context, ref, d);
                        },
                        // P2：长按 = 快速添加（与点按预览区分开，
                        // 此前两者行为完全相同）
                        onDayLongPress: (d) {
                          notifier.setSelectedDay(d);
                          _openQuickAdd(context, ref, initialDay: d);
                        },
                      ),
                      'week' => WeekView(
                        key: const ValueKey('view-week'),
                        items: state.items,
                        byDay: state.byDay,
                        selectedDay: state.selectedDay,
                        // 周↔日切换共享滚动位置
                        sharedScrollOffset: notifier.globalScrollOffset,
                        onDayChanged: (d) {
                          notifier.setSelectedDay(d);
                        },
                      ),
                      'day' => DayView(
                        key: const ValueKey('view-day'),
                        items: state.items,
                        byDay: state.byDay,
                        selectedDay: state.selectedDay,
                        sharedScrollOffset: notifier.globalScrollOffset,
                        onDayChanged: (d) {
                          notifier.setSelectedDay(d);
                        },
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        // 左边缘手势区（覆盖时间栏区域，44dp）：右滑 → 上一个 tab（任务）
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: leftEdgeWidth,
          child: _EdgeSwipeStrip(
            onSwipeRight: onNavigateLeft,
          ),
        ),
        // 右边缘手势区（40dp）：左滑 → 下一个 tab（四象限）
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: rightEdgeWidth,
          child: _EdgeSwipeStrip(
            onSwipeLeft: onNavigateRight,
          ),
        ),
      ],
    ),
    );
  }

  /// E9：标题随当前视图变化
  String _titleFor(CalendarState state) {
    final d = state.selectedDay;
    switch (state.view) {
      case 'month':
        return DateUtilsEx.monthCn(state.displayedMonth);
      case 'week':
        final monday = DateUtilsEx.mondayOf(d);
        final sunday = monday.add(const Duration(days: 6));
        // P2：跨月周（如 8/31-9/6）拆分显示，此前"8月 31-6日"误导
        if (monday.month == sunday.month) {
          return '${DateUtilsEx.monthCn(monday)} '
              '${monday.day}-${sunday.day}日';
        }
        return '${monday.month}月${monday.day}日-'
            '${sunday.month}月${sunday.day}日';
      case 'day':
        return DateUtilsEx.dateCn(d);
    }
    return DateUtilsEx.monthCn(state.displayedMonth);
  }

  Future<void> _pickDate(
    BuildContext context,
    CalendarController notifier,
    CalendarState state,
  ) async {
    final now = AppClock.now();
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 5);
    // P1-27：周/日视图可翻数百年前，selectedDay 超界会触发 DatePicker
    // 断言崩溃，钳制到 [firstDate, lastDate]
    final initial = state.selectedDay;
    final clamped = initial.isBefore(first)
        ? first
        : (initial.isAfter(last) ? last : initial);
    final picked = await showDatePicker(
      context: context,
      initialDate: clamped,
      firstDate: first,
      lastDate: last,
      helpText: '选择日期',
    );
    if (picked != null) {
      notifier.setSelectedDay(picked);
    }
  }

  void _openQuickAdd(BuildContext context, WidgetRef ref, {DateTime? initialDay}) {
    final day = initialDay ?? AppClock.now();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => QuickAddSheetWithDefaults(day),
    );
  }

  void _openDayPreview(BuildContext context, WidgetRef ref, DateTime day) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => DayPreviewSheet(day: day),
    );
  }
}

/// 边缘滑动切 tab 手势区（丝滑交互）：
/// 覆盖屏幕左/右边缘独立区域（视图已让位，与其零手势竞争），
/// 累计位移 ≥24dp 即触发（此前依赖 velocity>400 难以触发）；
/// 右滑 → [onSwipeRight]，左滑 → [onSwipeLeft]。
/// 拖动任务到边缘翻周/日由 Draggable 全局坐标驱动（views.dart _handleDragGlobal），
/// 与此手势区互不干扰（拖动起点在任务块上，本区 recognizer 不参与）。
class _EdgeSwipeStrip extends StatefulWidget {
  const _EdgeSwipeStrip({this.onSwipeRight, this.onSwipeLeft});

  final VoidCallback? onSwipeRight;
  final VoidCallback? onSwipeLeft;

  @override
  State<_EdgeSwipeStrip> createState() => _EdgeSwipeStripState();
}

class _EdgeSwipeStripState extends State<_EdgeSwipeStrip> {
  /// 累计水平位移（手势内）
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _dx = 0,
      onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
      onHorizontalDragEnd: (_) {
        // 位移 ≥24dp 且方向明确 → 切 tab（不依赖速度，慢速滑动也可触发）
        if (_dx > 24) {
          widget.onSwipeRight?.call();
        } else if (_dx < -24) {
          widget.onSwipeLeft?.call();
        }
        _dx = 0;
      },
      onHorizontalDragCancel: () => _dx = 0,
      child: const ColoredBox(color: Colors.transparent),
    );
  }
}

/// E12：日历侧边栏（视图切换/添加/月份导航）
class _CalendarDrawer extends ConsumerWidget {
  const _CalendarDrawer({
    required this.state,
    required this.onViewChanged,
    required this.onAdd,
    required this.onPickDate,
  });

  final CalendarState state;
  final ValueChanged<String> onViewChanged;
  final VoidCallback onAdd;
  final ValueChanged<DateTime> onPickDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('日历', style: Theme.of(context).textTheme.titleLarge),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_view_month),
              title: const Text('月视图'),
              selected: state.view == 'month',
              onTap: () {
                onViewChanged('month');
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.view_week),
              title: const Text('周视图'),
              selected: state.view == 'week',
              onTap: () {
                onViewChanged('week');
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.view_day),
              title: const Text('日视图'),
              selected: state.view == 'day',
              onTap: () {
                onViewChanged('day');
                Navigator.pop(context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加任务'),
              onTap: () {
                Navigator.pop(context);
                onAdd();
              },
            ),
            const Divider(),
            // 月份导航（翻月）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () {
                      final m = state.displayedMonth;
                      onPickDate(DateTime(m.year, m.month - 1, 1));
                    },
                  ),
                  Expanded(
                    child: Text(
                      DateUtilsEx.monthCn(state.displayedMonth),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () {
                      final m = state.displayedMonth;
                      onPickDate(DateTime(m.year, m.month + 1, 1));
                    },
                  ),
                ],
              ),
            ),
            // 顶部标题可点击选择日期，此处不再提供日期选择器
          ],
        ),
      ),
    );
  }
}

/// 月视图（E11：左右滑动翻月）
/// 6.9：PageController 由 State 持有并在 dispose 释放
/// （此前在 build 中创建，刷新时月份位置可能重置）
class MonthPager extends ConsumerStatefulWidget {
  const MonthPager({
    super.key,
    required this.items,
    required this.byDay,
    required this.displayedMonth,
    required this.selectedDay,
    required this.onMonthChanged,
    required this.onDayTap,
    required this.onDayLongPress,
  });

  final List<CalendarItem> items;
  /// 按天分组索引（P2-1：月视图不再逐项遍历建分组）
  final Map<int, List<CalendarItem>> byDay;
  final DateTime displayedMonth;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<DateTime> onDayLongPress;

  @override
  ConsumerState<MonthPager> createState() => _MonthPagerState();
}

class _MonthPagerState extends ConsumerState<MonthPager> {
  static const _baseYear = 2000;
  late final PageController _controller;

  int _indexOf(DateTime m) => (m.year - _baseYear) * 12 + m.month - 1;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _indexOf(widget.displayedMonth));
  }

  @override
  void didUpdateWidget(MonthPager old) {
    super.didUpdateWidget(old);
    // 外部切换月份（顶部标题/今天按钮/日期选中）→ 平滑翻到对应页
    // A13：animateToPage 替代 jumpToPage——外部跳转不再"硬切"
    final oldIdx = _indexOf(old.displayedMonth);
    final newIdx = _indexOf(widget.displayedMonth);
    if (oldIdx != newIdx && _controller.hasClients) {
      _controller.animateToPage(
        newIdx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      onPageChanged: (page) {
        final year = _baseYear + page ~/ 12;
        final month = page % 12 + 1;
        widget.onMonthChanged(DateTime(year, month, 1));
      },
      itemBuilder: (context, page) {
        final year = _baseYear + page ~/ 12;
        final month = page % 12 + 1;
        return MonthView(
          items: widget.items,
          byDay: widget.byDay,
          displayedMonth: DateTime(year, month, 1),
          selectedDay: widget.selectedDay,
          onDayTap: widget.onDayTap,
          onDayLongPress: widget.onDayLongPress,
        );
      },
    );
  }
}

/// 月视图
class MonthView extends ConsumerWidget {
  const MonthView({
    super.key,
    required this.items,
    required this.byDay,
    required this.displayedMonth,
    required this.selectedDay,
    required this.onDayTap,
    required this.onDayLongPress,
  });

  /// 单个日期格子最多显示的任务块数（超出显示 +N）
  static const _monthMaxItems = 2;

  final List<CalendarItem> items;
  /// 按天分组索引（key = yyyymmdd 整数）
  final Map<int, List<CalendarItem>> byDay;
  final DateTime displayedMonth;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<DateTime> onDayLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = DateUtilsEx.firstOfMonth(displayedMonth);
    final daysInMonth = DateUtilsEx.daysInMonth(displayedMonth);
    final leadingBlanks = first.weekday - 1; // 周一为起始
    final totalCells = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;

    final byDay = this.byDay;

    return Column(
      children: [
        Row(
          children: DateUtilsEx.weekdayCn
              .map(
                (w) => Expanded(
                  child: Center(
                    child: Text(
                      w,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.82,
            ),
            itemCount: totalCells,
            itemBuilder: (context, index) {
              final dayNum = index - leadingBlanks + 1;
              if (dayNum < 1 || dayNum > daysInMonth) {
                return const SizedBox.shrink();
              }
              final date = DateTime(
                displayedMonth.year,
                displayedMonth.month,
                dayNum,
              );
              final isToday = DateUtilsEx.sameDay(date, AppClock.now());
              final isSelected = DateUtilsEx.sameDay(date, selectedDay);
              final dayItems = byDay[date.year * 10000 + date.month * 100 + date.day] ??
                  const [];
              return InkWell(
                onTap: () => onDayTap(date),
                onLongPress: () => onDayLongPress(date),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isToday
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$dayNum',
                          style: TextStyle(
                            fontSize: 12,
                            color: isToday
                                ? Theme.of(context).colorScheme.onPrimary
                                : null,
                            fontWeight: isToday ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 当天任务块均分填满格子（最多显示 5 个）
                            for (final item in dayItems.take(_monthMaxItems))
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: _MonthTaskLine(item: item),
                                ),
                              ),
                            if (dayItems.length > _monthMaxItems)
                              Text(
                                '+${dayItems.length - _monthMaxItems}',
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
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MonthTaskLine extends StatelessWidget {
  const _MonthTaskLine({required this.item});

  final CalendarItem item;

  @override
  Widget build(BuildContext context) {
    final t = item.task;
    final done = item.completed;
    final listColor = colorFromHex(item.listColor);
    final color = done ? Colors.grey.shade400 : listColor;
    const radius = 6.0;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: done ? Theme.of(context).colorScheme.surfaceContainerHighest : listColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Stack(
        children: [
          // 清单色线：紧贴块左边缘，与圆角直边同高
          Positioned(
            left: 0,
            top: radius,
            bottom: radius,
            child: Container(width: 1, color: color),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: done ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
