import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/calendar/calendar_sheets.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';
import 'package:zhuoluo/features/calendar/views.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 日历页：顶部切换月/周/日视图并选择日期。
/// 水平滑动只翻当前日历视图，底部页面通过底部导航切换。
class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key, this.isActive = true});

  /// IndexedStack 中只有当前日历 Tab 可以接管系统返回键。
  final bool isActive;

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  bool _showMiniMonth = false;
  late DateTime _miniMonth = AppClock.at(
    AppClock.now().year,
    AppClock.now().month,
    1,
  );

  void _closeMiniMonth() {
    if (_showMiniMonth) setState(() => _showMiniMonth = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(calendarControllerProvider);
    final notifier = ref.read(calendarControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !widget.isActive || !_showMiniMonth,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !widget.isActive) return;
        _closeMiniMonth();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 16,
          title: InkWell(
            key: const ValueKey('calendar-date-title'),
            borderRadius: AppRadius.tile,
            onTap: () {
              setState(() {
                _miniMonth = AppClock.at(
                  state.selectedDay.year,
                  state.selectedDay.month,
                  1,
                );
                _showMiniMonth = !_showMiniMonth;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _titleFor(state),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                Icon(
                  _showMiniMonth
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 18,
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              onPressed: () {
                _closeMiniMonth();
                notifier.goToToday();
              },
              icon: const Icon(Icons.today_outlined),
              tooltip: '今天',
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: PopupMenuButton<String>(
                key: const ValueKey('calendar-view-menu'),
                tooltip: '切换视图',
                initialValue: state.view,
                onSelected: (view) {
                  _closeMiniMonth();
                  notifier.setView(view);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'month', child: Text('月视图')),
                  PopupMenuItem(value: 'week', child: Text('周视图')),
                  PopupMenuItem(value: 'day', child: Text('日视图')),
                ],
                child: Container(
                  height: 40,
                  constraints: const BoxConstraints(minWidth: 82),
                  padding: const EdgeInsets.only(left: 12, right: 7),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: AppRadius.pill,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        switch (state.view) {
                          'month' => '月视图',
                          'day' => '日视图',
                          _ => '周视图',
                        },
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          key: const ValueKey('calendar-add-button'),
          tooltip: '添加任务',
          onPressed: () {
            _closeMiniMonth();
            _openQuickAdd(context, state.selectedDay);
          },
          child: const Icon(Icons.add_rounded, size: 30),
        ),
        body: Stack(
          children: [
            // 视图铺满全屏
            Positioned.fill(
              child: Column(
                children: [
                  Expanded(
                    // 仅首次加载（loading 只在首载为 true）显示 spinner；后续
                    // load（改期/勾选/翻页）不整页替换——否则视图 State 销毁、
                    // 滚动位置/翻页位置全部重置，拖拽中翻页跨缓存点虚影/落点失效
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
                                onMonthChanged: (m) =>
                                    notifier.setDisplayedMonth(m),
                                onDayTap: (d) {
                                  notifier.setSelectedDay(d);
                                  showModalBottomSheet<void>(
                                    context: context,
                                    isScrollControlled: true,
                                    builder: (_) => DayPreviewSheet(
                                      day: d,
                                      onOpenDayView: () => notifier
                                          .setSelectedDayWithView(d, 'day'),
                                    ),
                                  );
                                },
                                // 长按直接为该日期添加任务。
                                onDayLongPress: (d) {
                                  notifier.setSelectedDay(d);
                                  _openQuickAdd(context, d);
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
            if (_showMiniMonth)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeMiniMonth,
                  child: ColoredBox(
                    color: scheme.scrim.withValues(alpha: 0.08),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_showMiniMonth,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.08),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _showMiniMonth
                      ? _MiniMonthPicker(
                          month: _miniMonth,
                          selectedDay: state.selectedDay,
                          onMonthChanged: (m) => setState(() => _miniMonth = m),
                          onDayTap: (d) {
                            _closeMiniMonth();
                            notifier.setSelectedDay(d);
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部仅显示年月；周/日的具体日期由视图表头展示。
  String _titleFor(CalendarState state) {
    final day = state.view == 'month'
        ? state.displayedMonth
        : state.selectedDay;
    return DateUtilsEx.monthCn(day);
  }

  void _openQuickAdd(BuildContext context, DateTime day) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 快建呼出提速：默认 250ms 动画 + 键盘弹出叠加体感慢，缩短到 120ms
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 120),
        reverseDuration: Duration(milliseconds: 120),
      ),
      builder: (c) => QuickAddSheetWithDefaults(day),
    );
  }
}

/// 顶部展开的日期导航，不改变正在浏览的月／周／日视图。
class _MiniMonthPicker extends StatelessWidget {
  const _MiniMonthPicker({
    required this.month,
    required this.selectedDay,
    required this.onMonthChanged,
    required this.onDayTap,
  });

  final DateTime month;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = AppClock.at(month.year, month.month, 1);
    final leading = first.weekday - 1;
    final cellCount = ((leading + DateUtilsEx.daysInMonth(month) + 6) ~/ 7) * 7;
    final today = AppClock.now();
    return Material(
      key: const ValueKey('calendar-mini-month'),
      elevation: 8,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '上个月',
                  onPressed: month.year == 2000 && month.month == 1
                      ? null
                      : () => onMonthChanged(
                          AppClock.at(month.year, month.month - 1, 1),
                        ),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    DateUtilsEx.monthCn(month),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '下个月',
                  onPressed: month.year == 2099 && month.month == 12
                      ? null
                      : () => onMonthChanged(
                          AppClock.at(month.year, month.month + 1, 1),
                        ),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            Row(
              children: [
                for (final weekday in DateUtilsEx.weekdayCn)
                  Expanded(
                    child: Center(
                      child: Text(
                        weekday,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (var row = 0; row < cellCount ~/ 7; row++)
              Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final date = AppClock.addCalendarDays(
                            first,
                            row * 7 + col - leading,
                          );
                          final inRange =
                              date.year >= 2000 && date.year <= 2099;
                          final isToday = DateUtilsEx.sameDay(date, today);
                          final isSelected = DateUtilsEx.sameDay(
                            date,
                            selectedDay,
                          );
                          return SizedBox(
                            height: 40,
                            child: InkWell(
                              key: ValueKey(
                                'mini-day-${date.year}-${date.month}-${date.day}',
                              ),
                              onTap: inRange ? () => onDayTap(date) : null,
                              borderRadius: AppRadius.pill,
                              child: Center(
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isToday
                                        ? scheme.primary
                                        : isSelected
                                        ? scheme.primaryContainer
                                        : null,
                                  ),
                                  child: Text(
                                    '${date.day}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isToday || isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                      color: isToday
                                          ? scheme.onPrimary
                                          : isSelected
                                          ? scheme.onPrimaryContainer
                                          : date.month == month.month
                                          ? scheme.onSurface
                                          : scheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
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

  /// 按天分组索引（月视图不再逐项遍历建分组）
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

  /// 外部跳月目标页（今天按钮/标题/日期选中）——动画期间 onPageChanged
  /// 拦截回写 displayedMonth，防回跳打断动画停在中间月
  int? _pendingExternalPage;

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
      final current = _controller.page?.round() ?? newIdx;
      // 手动翻月后 displayedMonth 已同步（onPageChanged 回写）→ 跳过
      if (current == newIdx) return;
      _pendingExternalPage = newIdx;
      _controller
          .animateToPage(
            newIdx,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (mounted) _pendingExternalPage = null;
          });
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
        final m = DateTime(year, month, 1);
        // 外部跳月动画期间：onPageChanged 多次触发（round 变化），只同步
        // 目标月不回写 displayedMonth（防回跳打断动画停在中间月）；到达
        // 目标页结束拦截（动画结束时 whenComplete 也会清理）
        if (_pendingExternalPage != null) {
          if (page == _pendingExternalPage) {
            _pendingExternalPage = null;
          }
          return;
        }
        widget.onMonthChanged(m);
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
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: DateUtilsEx.weekdayCn
                .map(
                  (w) => Expanded(
                    child: Center(
                      child: Text(
                        w,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        Expanded(
          // 六行月份也随可用高度收缩；月格仅展示任务标记。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rows = totalCells ~/ 7;
              final cellH = (constraints.maxHeight / rows)
                  .floorToDouble()
                  .clamp(48.0, 320.0);
              return GridView.builder(
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisExtent: cellH,
                ),
                itemCount: totalCells,
                itemBuilder: (context, index) {
                  final dayNum = index - leadingBlanks + 1;
                  // 相邻月灰化（谷歌日历风格）：前后补位显示上月/下月的日期数字，
                  // 点击跳转到对应月；不再是空白占位
                  final isCurrentMonth = dayNum >= 1 && dayNum <= daysInMonth;
                  final date = isCurrentMonth
                      ? AppClock.at(
                          displayedMonth.year,
                          displayedMonth.month,
                          dayNum,
                        )
                      : AppClock.addCalendarDays(
                          AppClock.at(
                            displayedMonth.year,
                            displayedMonth.month,
                            1,
                          ),
                          dayNum - 1,
                        );
                  final isToday = DateUtilsEx.sameDay(date, AppClock.now());
                  final isSelected = DateUtilsEx.sameDay(date, selectedDay);
                  final dayKey =
                      date.year * 10000 + date.month * 100 + date.day;
                  final dayItems = byDay[dayKey] ?? const [];
                  return InkWell(
                    key: ValueKey(
                      'month-day-${date.year}-${date.month}-${date.day}',
                    ),
                    onTap: () => onDayTap(date),
                    onLongPress: () => onDayLongPress(date),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.42,
                            ),
                            width: 0.5,
                          ),
                          bottom: BorderSide(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.42,
                            ),
                            width: 0.5,
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 3,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isToday
                                  ? scheme.primary
                                  : isSelected
                                  ? scheme.primaryContainer
                                  : null,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${date.day}',
                              style: TextStyle(
                                fontSize: 15,
                                color: isToday
                                    ? scheme.onPrimary
                                    : isSelected
                                    ? scheme.onPrimaryContainer
                                    : isCurrentMonth
                                    ? scheme.onSurface
                                    : scheme.outline,
                                fontWeight: isToday || isSelected
                                    ? FontWeight.w700
                                    : null,
                              ),
                            ),
                          ),
                          if (dayItems.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (
                                    var i = 0;
                                    i <
                                        (dayItems.length > 3
                                            ? 2
                                            : dayItems.length);
                                    i++
                                  )
                                    Container(
                                      key: ValueKey('calendar-task-dot-$i'),
                                      width: 6,
                                      height: 6,
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: dayItems[i].completed
                                            ? scheme.outline
                                            : colorFromHex(
                                                dayItems[i].listColor,
                                              ),
                                      ),
                                    ),
                                  if (dayItems.length > 3)
                                    Text(
                                      '+${dayItems.length - 2}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurfaceVariant,
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
              );
            },
          ),
        ),
      ],
    );
  }
}
