import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/theme/task_colors.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/core/utils/task_ext.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 时间轴基础参数
const _startHour = 6;
const _endHour = 23;
const _pixelPerHour = 64.0;

/// 按天索引 key（与 CalendarController 的 byDay 同口径）
int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

/// P1-8：时间轴起始小时——显示范围内最早 timed 任务（非全天/非跨天/
/// 有计划时间）的开始小时，与默认值取小：只扩展不收缩，多数情况保持
/// 06:00 起点；有 06:00 前任务时起始点下移，任务不再隐形不可操作。
/// P2-1/丝滑翻页：改为按天分组数据驱动——此前遍历整个窗口 items
/// （每次 build O(N×7)），现只扫显示范围内 7 天。
int effectiveStartHourFor({
  required Map<int, List<CalendarItem>> byDay,
  required List<DateTime> days,
  int defaultStart = _startHour,
}) {
  var earliest = defaultStart;
  for (final d in days) {
    for (final it in byDay[_dayKey(d)] ?? const <CalendarItem>[]) {
      if (_AllDayBar.isTopArea(it)) continue;
      final h = it.task.planStart?.hour ?? defaultStart;
      if (h < earliest) earliest = h;
    }
  }
  return earliest;
}

/// 周视图：多周横滚（PageView，E11 保留滑动）
/// 支持拖拽/选时到屏幕边缘自动翻周（任务7）
class WeekView extends ConsumerStatefulWidget {
  const WeekView({
    super.key,
    required this.items,
    required this.byDay,
    required this.selectedDay,
    required this.onDayChanged,
    this.sharedScrollOffset,
  });

  final List<CalendarItem> items;
  /// 按天分组索引（P2-1：视图 build 不再全窗口扫描）
  final Map<int, List<CalendarItem>> byDay;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onDayChanged;
  /// 跨视图共享的垂直滚动位置（周↔日切换时保持位置连续，不跳回顶部）
  final ValueNotifier<double>? sharedScrollOffset;

  @override
  ConsumerState<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends ConsumerState<WeekView> {
  final PageController _controller = PageController(initialPage: 500);

  /// 拖动/选时跨页时的目标日期（随翻页更新；初始=当前显示周的周一）
  final ValueNotifier<DateTime> _dragDay = ValueNotifier<DateTime>(
    AppClock.now(),
  );

  /// 共享边缘滞回状态（贯穿所有页，不随翻页重建丢失）：
  /// 0=未触发，1=向右已翻，-1=向左已翻；手指回中间才允许再次触发
  final ValueNotifier<int> _edgeState = ValueNotifier<int>(0);

  /// 共享垂直滚动位置（跨周翻页时新周继承当前滚动位置，避免跳回顶部）
  /// 优先使用外部传入的共享 notifier（周↔日切换连续）
  late final ValueNotifier<double> _sharedScrollOffset;
  ValueNotifier<double>? _ownScroll;

  int _lastTurnMs = 0;
  int _lastTurnDir = 0; // 跨页共享的方向节流：同方向短时间内不重复翻页

  /// P1-D：外部跳页目标页。跳页触发的 onPageChanged 只同步 _dragDay、
  /// 不回写 selectedDay（否则点"今天"后选中日被回归为周一）。
  int? _pendingExternalPage;

  /// P0-1：固定周基准（initState 时刻的当前周周一），state 生命周期内
  /// 不再变化，与 DayView 固定日基准（2000-01-01）同一模式。此前以
  /// mondayOf(widget.selectedDay) 为基准，而 didUpdateWidget 中
  /// widget.selectedDay 已是新值 → 差恒为 0 → 目标页恒为 500：
  /// 手动翻周必触发 280ms 弹回动画、跨周外部跳转恒落回 App 打开时
  /// 那一周（上版误判 P0-15 已修复，本轮翻案）。
  late final DateTime _epochMonday;

  int _pageForMonday(DateTime monday) =>
      500 + monday.difference(_epochMonday).inDays ~/ 7;

  @override
  void initState() {
    super.initState();
    _epochMonday = DateUtilsEx.mondayOf(AppClock.now());
    _sharedScrollOffset =
        widget.sharedScrollOffset ?? (_ownScroll = ValueNotifier<double>(0));
    _dragDay.value = DateUtilsEx.mondayOf(widget.selectedDay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.hasClients) {
        final target = _pageForMonday(
          DateUtilsEx.mondayOf(widget.selectedDay),
        );
        // P0-1：固定基准下初始页可能远离 500，jump 会触发
        // onPageChanged——用 _pendingExternalPage 拦截回写
        // selectedDay（与 didUpdateWidget 外部跳转同机制）
        _pendingExternalPage = target;
        _controller.jumpToPage(target);
      }
    });
  }

  @override
  void didUpdateWidget(WeekView old) {
    super.didUpdateWidget(old);
    final oldMonday = DateUtilsEx.mondayOf(old.selectedDay);
    final newMonday = DateUtilsEx.mondayOf(widget.selectedDay);
    if (!DateUtilsEx.sameDay(oldMonday, newMonday) && _controller.hasClients) {
      final target = _pageForMonday(newMonday);
      final current = _controller.page?.round() ?? target;
      // A13：用户手势翻页后 selectedDay 已同步到新周（onPageChanged 回调），
      // 此时当前页即目标页——若再走 animateToPage 会误判为外部跳转，
      // 每次翻页后追加一段 280ms 多余动画，观感"不跟手/发涩"。直接跳过。
      if (current == target) {
        _dragDay.value = newMonday;
        return;
      }
      // 外部切换日期（今天按钮/月视图选日）→ 平滑翻到对应周
      _pendingExternalPage = target;
      _controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      _dragDay.value = newMonday;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _dragDay.dispose();
    _edgeState.dispose();
    // 仅释放自建的滚动 notifier（外部传入的由持有者管理）
    _ownScroll?.dispose();
    super.dispose();
  }

  /// 边缘翻页（双节流：同方向 2 秒内不重复；翻页后手指需回中间才能再翻）
  void _edgeTurn(double dx) {
    final nowMs = AppClock.now().millisecondsSinceEpoch;
    final dir = dx > 0 ? 1 : -1;
    if (dir == _lastTurnDir && nowMs - _lastTurnMs < 2000) return;
    _lastTurnDir = dir;
    _lastTurnMs = nowMs;
    final page = _controller.page?.round() ?? 500;
    if (dx > 0) {
      // 手指靠近右缘 → 下一页（下一周）
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _controller.previousPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    // 同步目标日
    final offset = page - 500 + (dx > 0 ? 1 : -1);
    _dragDay.value = _epochMonday.add(Duration(days: offset * 7));
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      // P0-1：itemCount 随固定基准同步扩大（自 _epochMonday 起每周一页，
      // 与 DayView 的 40000 对称，前后各覆盖约 380 年）
      itemCount: 40000,
      // A13：allowImplicitScrolling 预构建页在 widget 测试 teardown 时
      // 触发 deactivate 时序问题（_NowLine Timer pending），暂不启用；
      // 丝滑翻页主要靠窗口缓存（翻页零 DB）+ byDay 分组 build 减负
      onPageChanged: (page) {
        final offset = page - 500;
        final weekMonday = _epochMonday.add(Duration(days: offset * 7));
        // P1-D：外部跳页（今天按钮/日期选择）→ 只同步 _dragDay，
        // 不回写 selectedDay（否则选中日被覆盖为周一）
        if (_pendingExternalPage != null && page == _pendingExternalPage) {
          _pendingExternalPage = null;
          _dragDay.value = weekMonday;
          return;
        }
        _pendingExternalPage = null;
        // P1-D：手动翻页时同步 _dragDay（与 DayView 一致），
        // 修复翻周后长按选时创建到旧周的问题
        _dragDay.value = weekMonday;
        widget.onDayChanged(weekMonday);
      },
      itemBuilder: (context, page) {
        final offset = page - 500;
        final weekStart = _epochMonday.add(Duration(days: offset * 7));
        return _KeepAlive(
          child: _TimeAxisView(
            items: widget.items,
            byDay: widget.byDay,
            start: weekStart,
            isWeek: true,
            selectedDay: widget.selectedDay,
            dragDay: _dragDay,
            edgeState: _edgeState,
            scrollOffsetShare: _sharedScrollOffset,
            onEdgeTurn: _edgeTurn,
          ),
        );
      },
    );
  }
}

/// 日视图（左右滑动翻日，支持拖拽/选时到屏幕边缘自动翻日）
class DayView extends ConsumerStatefulWidget {
  const DayView({
    super.key,
    required this.items,
    required this.byDay,
    required this.selectedDay,
    required this.onDayChanged,
    this.sharedScrollOffset,
  });

  final List<CalendarItem> items;
  /// 按天分组索引（P2-1：视图 build 不再全窗口扫描）
  final Map<int, List<CalendarItem>> byDay;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onDayChanged;
  /// 跨视图共享的垂直滚动位置（周↔日切换时保持位置连续）
  final ValueNotifier<double>? sharedScrollOffset;

  @override
  ConsumerState<DayView> createState() => _DayViewState();
}

class _DayViewState extends ConsumerState<DayView> {
  late final PageController _controller;
  final ValueNotifier<DateTime> _dragDay = ValueNotifier<DateTime>(
    AppClock.now(),
  );
  /// 共享边缘滞回状态（同 WeekView）
  final ValueNotifier<int> _edgeState = ValueNotifier<int>(0);

  /// 共享垂直滚动位置（跨日翻页时新日继承当前滚动位置）
  /// 优先使用外部传入的共享 notifier（周↔日切换连续）
  late final ValueNotifier<double> _sharedScrollOffset;
  ValueNotifier<double>? _ownScroll;
  int _lastTurnMs = 0;
  int _lastTurnDir = 0; // 跨页共享的方向节流

  int _pageFor(DateTime d) =>
      DateTime(d.year, d.month, d.day).difference(DateTime(2000, 1, 1)).inDays;

  @override
  void initState() {
    super.initState();
    _sharedScrollOffset =
        widget.sharedScrollOffset ?? (_ownScroll = ValueNotifier<double>(0));
    _controller = PageController(initialPage: _pageFor(widget.selectedDay));
    _dragDay.value = widget.selectedDay;
  }

  @override
  void didUpdateWidget(DayView old) {
    super.didUpdateWidget(old);
    if (!DateUtilsEx.sameDay(old.selectedDay, widget.selectedDay) &&
        _controller.hasClients) {
      // A13：外部跳日平滑过渡（替代瞬间 jumpToPage）
      _controller.animateToPage(
        _pageFor(widget.selectedDay),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      _dragDay.value = widget.selectedDay;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _dragDay.dispose();
    _edgeState.dispose();
    // 仅释放自建的滚动 notifier（外部传入的由持有者管理）
    _ownScroll?.dispose();
    super.dispose();
  }

  void _edgeTurn(double dx) {
    final nowMs = AppClock.now().millisecondsSinceEpoch;
    final dir = dx > 0 ? 1 : -1;
    if (dir == _lastTurnDir && nowMs - _lastTurnMs < 2000) return;
    _lastTurnDir = dir;
    _lastTurnMs = nowMs;
    final page = _controller.page?.round() ?? 0;
    if (dx > 0) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _controller.previousPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    _dragDay.value = DateTime(
      2000,
      1,
      1,
    ).add(Duration(days: page + (dx > 0 ? 1 : -1)));
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      itemCount: 40000,
      // A13：allowImplicitScrolling 预构建页在 widget 测试 teardown 时
      // 触发 deactivate 时序问题（_NowLine Timer pending），暂不启用；
      // 丝滑翻页主要靠窗口缓存（翻页零 DB）+ byDay 分组 build 减负
      onPageChanged: (page) {
        _dragDay.value = DateTime(2000, 1, 1).add(Duration(days: page));
        widget.onDayChanged(_dragDay.value);
      },
      itemBuilder: (context, page) {
        final day = DateTime(2000, 1, 1).add(Duration(days: page));
        return _KeepAlive(
          child: _TimeAxisView(
            items: widget.items,
            byDay: widget.byDay,
            start: day,
            isWeek: false,
            selectedDay: widget.selectedDay,
            dragDay: _dragDay,
            edgeState: _edgeState,
            scrollOffsetShare: _sharedScrollOffset,
            onEdgeTurn: _edgeTurn,
          ),
        );
      },
    );
  }
}

/// 保持 PageView 子页存活（拖动跨页时状态不丢）
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 时间轴视图（周/日共用）
/// E5：左侧时间栏与右侧内容共享 ScrollController 联动滚动
/// E4：红线随系统时间实时刷新（每分钟）
/// E3：红线仅显示在今天列
class _TimeAxisView extends ConsumerStatefulWidget {
  const _TimeAxisView({
    required this.items,
    required this.byDay,
    required this.start,
    required this.isWeek,
    required this.selectedDay,
    this.dragDay,
    this.edgeState,
    this.scrollOffsetShare,
    this.onEdgeTurn,
  });

  final List<CalendarItem> items;
  /// 按天分组索引（P2-1：build 不再全窗口扫描）
  final Map<int, List<CalendarItem>> byDay;
  final DateTime start;
  final bool isWeek;
  final DateTime selectedDay;

  /// 拖动/选时跨页时的目标日期（边缘翻页时由上层更新）
  final ValueNotifier<DateTime>? dragDay;

  /// 共享边缘滞回状态（WeekView/DayView 持有，跨页共享）
  final ValueNotifier<int>? edgeState;

  /// 共享垂直滚动位置（WeekView/DayView 持有；翻页后新页继承当前滚动位置，
  /// 避免切周/切日时跳回顶部）
  final ValueNotifier<double>? scrollOffsetShare;

  /// 边缘翻页回调（参数：手指靠近右缘为正、左缘为负）
  final ValueChanged<double>? onEdgeTurn;

  @override
  ConsumerState<_TimeAxisView> createState() => _TimeAxisViewState();
}

class _TimeAxisViewState extends ConsumerState<_TimeAxisView> {
  final _scrollController = ScrollController();
  final _timeBarController = ScrollController();

  @override
  void initState() {
    super.initState();
    // E5：右侧内容滚动 → 左侧时间栏同步跟随 + 更新共享滚动位置
    _scrollController.addListener(_onScroll);
    // 不自动定位到当前时间：任何自动滚动都会在切换周/日、拖动改期时
    // 造成视觉跳变。时间轴位置完全由用户控制。
    // 翻页后新页继承共享滚动位置（切周/切日不跳回顶部）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final share = widget.scrollOffsetShare;
      if (share != null && share.value > 0 && _scrollController.hasClients) {
        _scrollController.jumpTo(
          share.value.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
    });
    // A7：移除每分钟整页 setState 的时钟 Timer——红线改由独立组件
    // _NowLine 自驱动，不再触发整个时间轴重建
  }

  void _onScroll() {
    _syncTimeBar();
    // 滚动位置同步到共享值（翻页后新页继承）
    final share = widget.scrollOffsetShare;
    if (share != null) {
      share.value = _scrollController.offset;
    }
  }

  void _syncTimeBar() {
    if (!_timeBarController.hasClients) return;
    final target = _scrollController.offset;
    if ((_timeBarController.offset - target).abs() > 0.5) {
      _timeBarController.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _timeBarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = widget.isWeek
        ? List.generate(7, (i) => widget.start.add(Duration(days: i)))
        : [widget.start];
    final notifier = ref.read(calendarControllerProvider.notifier);
    // A7：表头"今天"高亮由 build 时实时计算（跨天时随页面重建自然更新），
    // 不再依赖每分钟 setState 的 _now
    final today = AppClock.now();
    // P1-8：时间轴起始小时动态化——显示范围内最早 timed 任务决定
    //（默认 6；06:00 前任务存在时扩展起始点，任务不再隐形不可操作）
    final startEff = _effectiveStartHour(days);
    final totalHours = _endHour - startEff;

    // LayoutBuilder：拿实际可用宽度（布局收窄后 ≠ 屏宽，
    // 此前用 MediaQuery 全屏宽导致 RenderFlex overflow）
    return LayoutBuilder(
      builder: (context, constraints) {
        final axisWidth = constraints.maxWidth;
        return Column(
      children: [
        // 星期/日期头部
        Row(
          children: [
            const SizedBox(width: 44),
            for (final d in days)
              Expanded(
                child: InkWell(
                  onTap: widget.isWeek
                      // P2：合并为一次 load（此前 setSelectedDay+setView 两次）
                      ? () => notifier.setSelectedDayWithView(d, 'day')
                      // P2：日视图头部可点击跳转其他日期（此前点击无反应）
                      : () async {
                          final now = AppClock.now();
                          // P1-27：日视图可翻至 2000-01-01，当前显示日超界
                          // 会触发 DatePicker 断言崩溃，钳制到 [first, last]
                          final first = DateTime(now.year - 5);
                          final last = DateTime(now.year + 5);
                          final initial = widget.start;
                          final clamped = initial.isBefore(first)
                              ? first
                              : (initial.isAfter(last) ? last : initial);
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: clamped,
                            firstDate: first,
                            lastDate: last,
                            helpText: '跳转到日期',
                          );
                          if (picked != null && context.mounted) {
                            notifier.setSelectedDay(picked);
                          }
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        if (widget.isWeek) ...[
                          Text(
                            DateUtilsEx.weekdayCn[d.weekday - 1],
                            style: TextStyle(
                              fontSize: 11,
                              color: DateUtilsEx.sameDay(d, today)
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey.shade600,
                            ),
                          ),
                          Text(
                            '${d.day}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: DateUtilsEx.sameDay(d, today)
                                  ? FontWeight.bold
                                  : null,
                              color: DateUtilsEx.sameDay(d, today)
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                          ),
                        ] else
                          Text(
                            DateUtilsEx.dateCn(d),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 1),
        // 5.8/P1-8：时间轴可见范围说明（动态起始小时，06:00 前有任务时
        // 起始点扩展；超出时间轴范围的夜间任务仍不显示）
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 1, 12, 1),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              // 截图②：明确"可滚动"——消除"标注 06-23 但屏内只看到部分"的困惑
              '可滚动 · 时间轴 ${startEff.toString().padLeft(2, '0')}:00-23:00',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              // 全天区固定在顶部（不随滚动，保证左右时间栏与网格线严格对齐）
              if (days.any((d) => _allDayItems(d).isNotEmpty)) ...[
                _AllDayBar(days: days, byDay: widget.byDay, axisWidth: axisWidth),
                Divider(
                  height: 1,
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ],
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // E5：左侧时间刻度（跟随右侧滚动同步）
                    SizedBox(
                      width: 44,
                      child: ListView.builder(
                        controller: _timeBarController,
                        physics: const NeverScrollableScrollPhysics(),
                        // 上下各留半行高（与右侧内容对称），让首尾标签（6:00/23:00）完整显示
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        itemCount: totalHours + 1,
                        itemBuilder: (context, i) {
                          final hour = startEff + i;
                          return SizedBox(
                            height: _pixelPerHour,
                            // 标签中心对齐小时线（文字上下各 5px，跨线居中）
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  right: 0,
                                  top: -5,
                                  child: Text(
                                    '${hour.toString().padLeft(2, '0')}:00',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 10,
                                      height: 1,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // E5：右侧内容（同一滚动控制器）
                    Expanded(
                      child: ListView(
                        controller: _scrollController,
                        // 与左侧时间栏同步偏移，保持线对齐；
                        // 上下各留半行（32px），6:00 上方与 23:00 下方留白对称
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        children: [
                          // 时间轴主体（18 行，6:00~23:00 线）
                          SizedBox(
                            height: totalHours * _pixelPerHour,
                            child: Stack(
                              children: [
                                // 时间网格线（暗色适配）
                                for (var h = 0; h <= totalHours; h++)
                                  Positioned(
                                    top: h * _pixelPerHour - 0.5,
                                    left: 0,
                                    right: 0,
                                    child: Divider(
                                      height: 1,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                // 日期列 + 任务块
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // 与 _DayColumnState.columnWidth 同口径
                                    // （扣除时间栏 44px 后均分）
                                    for (var i = 0; i < days.length; i++) ...[
                                      Expanded(
                                        child: _DayColumn(
                                          day: days[i],
                                          items: _timedItems(days[i]),
                                          isWeek: widget.isWeek,
                                          startHour: startEff,
                                          axisWidth: axisWidth,
                                          dragDay: widget.dragDay,
                                          edgeState: widget.edgeState,
                                          scrollController: _scrollController,
                                          onEdgeTurn: widget.onEdgeTurn,
                                          // A13：列在视口内的左偏移（含分隔线）
                                          viewportLeft:
                                              i *
                                              ((axisWidth - 44) /
                                                  days.length +
                                                  1),
                                        ),
                                      ),
                                      if (days[i] != days.last)
                                        Container(
                                          width: 1,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outlineVariant
                                              .withValues(alpha: 0.5),
                                        ),
                                    ],
                                  ],
                                ),
                                // E3+E4：当前时间线（仅今天列，平滑走秒）
                                // A7：独立组件自驱动，不再每分钟重建整页
                                _NowLine(
                                  todayIndex: days.indexWhere(
                                    (d) => DateUtilsEx.sameDay(d, today),
                                  ),
                                  columnWidth: (axisWidth - 44) /
                                      days.length,
                                  startHour: startEff,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
      },
    );
  }

  /// 是否显示在顶部置顶区（全天 / 无计划时间 / 跨天任务）
  bool _isTopArea(CalendarItem i) => _AllDayBar.isTopArea(i);

  /// P1-8：显示范围内（当周/当天）timed 任务的最早开始小时，
  /// 与默认 6 取小——只扩展不收缩（多数情况保持 06:00 起点）。
  int _effectiveStartHour(List<DateTime> days) => effectiveStartHourFor(
    byDay: widget.byDay,
    days: days,
  );

  List<CalendarItem> _allDayItems(DateTime day) =>
      (widget.byDay[_dayKey(day)] ?? const <CalendarItem>[])
          .where(_isTopArea)
          .toList();

  List<CalendarItem> _timedItems(DateTime day) =>
      (widget.byDay[_dayKey(day)] ?? const <CalendarItem>[])
          .where((i) => !_isTopArea(i))
          .toList();

}

/// A7/A8：当前时间红线独立组件。
/// 自身 Timer 每秒检查分钟变化，跨分钟时用 55s 线性动画平滑移动
/// （走秒效果），只重绘自身——不再触发整个时间轴每分钟重建。
class _NowLine extends StatefulWidget {
  const _NowLine({
    required this.todayIndex,
    required this.columnWidth,
    required this.startHour,
  });

  /// 今天列索引（-1 = 不在今天，不显示）
  final int todayIndex;
  final double columnWidth;
  /// P1-8：时间轴起始小时（与 _TimeAxisView 动态起始一致，红线随之下移）
  final int startHour;

  @override
  State<_NowLine> createState() => _NowLineState();
}

class _NowLineState extends State<_NowLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _prevTop = 0;
  double _nextTop = 0;
  Timer? _ticker;

  double _topFor(DateTime t) {
    final minutes = t.hour * 60 + t.minute;
    return (minutes - widget.startHour * 60) / 60 * _pixelPerHour;
  }

  @override
  void initState() {
    super.initState();
    // 修复：controller 在 initState 提前初始化（此前 late final 懒初始化 +
    // Timer 回调首次访问——页面 deactivate 期间 createTicker 查找
    // TickerMode ancestor 报 "Looking up a deactivated widget's ancestor"，
    // 翻页/测试 teardown 时崩溃）
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 55),
      value: 1.0,
    );
    final now = AppClock.now();
    _prevTop = _topFor(now);
    _nextTop = _prevTop;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      // 页面被替换（deactivate）后 Timer 可能仍在跑：只更新数值，
      // 不触碰已 dispose 的 controller
      if (!mounted) return;
      final t = AppClock.now();
      final top = _topFor(t);
      if ((top - _nextTop).abs() > 0.01) {
        final delta = (top - _nextTop).abs();
        // C-2026-08-08：位移超过 1 小时跨度 = 异常跳变（应用时区切换 /
        // 系统时钟调整）——立即到位，不走 55s 走秒动画（否则红线会
        // 用 55 秒慢慢挪到目标位置）
        if (delta > _pixelPerHour) {
          _prevTop = top;
          _nextTop = top;
          _controller.value = 1.0;
        } else {
          _prevTop = _nextTop;
          _nextTop = top;
          _controller.forward(from: 0);
        }
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.todayIndex < 0) return const SizedBox.shrink();
    final lineColor = Theme.of(context).colorScheme.error;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final top = _prevTop + (_nextTop - _prevTop) * _controller.value;
        if (top < 0 || top > (_endHour - widget.startHour) * _pixelPerHour) {
          return const SizedBox.shrink();
        }
        return Positioned(
          top: top,
          left: widget.todayIndex * widget.columnWidth,
          width: widget.columnWidth,
          child: Container(
            height: 1.5,
            color: lineColor,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: lineColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 全天/跨天任务条：按天列对齐（跨天任务只出现在其覆盖的每一天下方，
/// 不再全部堆在整周顶部一条里）
class _AllDayBar extends ConsumerWidget {
  const _AllDayBar({
    required this.days,
    required this.byDay,
    required this.axisWidth,
  });

  final List<DateTime> days;
  /// 按天分组索引（P2-1：不再全窗口扫描）
  final Map<int, List<CalendarItem>> byDay;
  /// 内容区实际可用宽度（含左侧时间栏 44px；布局收窄后 ≠ 屏宽）
  final double axisWidth;

  /// 是否显示在顶部置顶区（全天 / 无计划时间 / 跨天任务）
  static bool isTopArea(CalendarItem i) {
    final t = i.task;
    if (t.isAllDay || t.planStart == null) return true;
    final ps = t.planStart!;
    final pe = t.planEnd ?? ps.add(const Duration(hours: 1));
    // 跨天：结束日期 ≠ 开始日期
    return !DateUtilsEx.sameDay(ps, pe);
  }

  List<CalendarItem> _allDayItems(DateTime day) =>
      (byDay[_dayKey(day)] ?? const <CalendarItem>[])
          .where(isTopArea)
          .toList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 与下方时间轴内容区同宽同起点（左侧 44px 时间栏占位），保证列严格对齐
    final contentWidth = axisWidth - 44;
    final columnWidth = contentWidth / days.length;
    return Row(
      children: [
        const SizedBox(width: 44),
        SizedBox(
          width: contentWidth,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final d in days)
                SizedBox(
                  width: columnWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in _allDayItems(d))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          // C5-1/C3-4：仅真正的全天任务 allDay=true；
                          // 跨天定时任务可拖回时间轴并显示起止时刻
                          child: _TaskBlock(
                            item: item,
                            allDay: item.task.isAllDay,
                            showTime: !item.task.isAllDay,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单日列（E7：长按拖动选择时间区间创建任务）
class _DayColumn extends ConsumerStatefulWidget {
  const _DayColumn({
    required this.day,
    required this.items,
    required this.isWeek,
    required this.startHour,
    required this.axisWidth,
    this.dragDay,
    this.edgeState,
    this.scrollController,
    this.onEdgeTurn,
    this.viewportLeft = 0,
  });

  final DateTime day;
  final List<CalendarItem> items;
  final bool isWeek;

  /// P1-8：时间轴起始小时（动态——显示范围内最早 timed 任务决定，
  /// 默认 6；有更早任务时扩展，保证 06:00 前任务可见可操作）
  final int startHour;

  /// 时间轴内容区实际可用宽度（含左侧时间栏 44px；
  /// LayoutBuilder 提供——布局收窄后 ≠ 屏宽，此前按 MediaQuery 计算
  /// 导致 RenderFlex overflow）
  final double axisWidth;

  /// 拖动/选时跨页时的目标日期（边缘翻页时由上层更新）
  final ValueNotifier<DateTime>? dragDay;

  /// 共享边缘滞回状态（WeekView/DayView 持有，跨页共享）
  final ValueNotifier<int>? edgeState;

  /// 时间轴滚动控制器（拖动到视口顶部/底部时自动滚动）
  final ScrollController? scrollController;

  /// 边缘翻页回调（参数：手指靠近右缘为正、左缘为负）
  final ValueChanged<double>? onEdgeTurn;

  /// A13：本列在时间轴视口内的左偏移（胶囊水平钳制到视口内用，
  /// 周视图每列约 50px，胶囊 78px 必须跨列，钳制基准是整个视口）
  final double viewportLeft;

  @override
  ConsumerState<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends ConsumerState<_DayColumn> {
  /// 单列宽度（周视图 7 列、日视图 1 列，扣除左侧时间栏 44px）
  double get columnWidth =>
      (widget.axisWidth - 44) / (widget.isWeek ? 7 : 1);

  // E7：拖动选时状态
  bool _dragSelecting = false;
  double? _dragStartY;
  double? _dragCurrentY;
  /// A13：拖选时手指原始位置（_dragCurrentY 会被重写为选区大端，
  /// 胶囊需显示"手指所指"的实时时间，故单独记录）
  double? _dragFingerY;

  // 拖动改期：当前拖入的任务与手指位置（顶部时间浮标）
  int? _dragTaskId;
  double? _dragY;
  /// A12：拖动虚影位置通知器——onMove 高频更新只触发虚影层重建，
  /// 不再 setState 重建整列任务块（此前拖动每帧重建整列 + O(n²) 布局）
  final ValueNotifier<double?> _ghostY = ValueNotifier<double?>(null);

  /// A13：悬浮时间胶囊位置（列内局部坐标）。
  /// 拖动改期路径走 notifier 只重建胶囊层（保持 A12 性能优化），
  /// 拖选路径在既有 setState 循环内同步更新。
  final ValueNotifier<Offset?> _hintPos = ValueNotifier<Offset?>(null);

  /// 选时目标日：
  /// - 未翻页（dragDay 与当前列同周/同日）→ 当前列 widget.day
  /// - 已边缘翻页 → 周视图 = dragDay 所在周周一 + 本列周内偏移；日视图 = dragDay
  DateTime get _targetDay {
    final dd = widget.dragDay?.value;
    if (dd == null) return widget.day;
    if (widget.isWeek) {
      final sameWeek = DateUtilsEx.sameDay(
        DateUtilsEx.mondayOf(dd),
        DateUtilsEx.mondayOf(widget.day),
      );
      if (sameWeek) return widget.day;
      return DateUtilsEx.mondayOf(
        dd,
      ).add(Duration(days: widget.day.weekday - 1));
    }
    if (DateUtilsEx.sameDay(dd, widget.day)) return widget.day;
    return dd;
  }

  /// 拖动中靠近屏幕边缘自动翻页（右缘→下一页/下一周，左缘→上一页/上一周）
  ///
  /// 三层防误触/防连翻：
  /// 1. 边缘区收紧到屏幕最外 6%/94%（周一/周日列约 14% 宽，拖任务到列内不误触）
  /// 2. 进入边缘区需持续停留 300ms 才触发（快速拖过定位不翻页）
  /// 3. 共享滞回状态（WeekView/DayView 持有，翻页换列不丢）：
  ///    同一方向翻页一次后需回中间区域才能再翻；拖动结束重置
  Timer? _edgeTimer;
  int _edgeDir = 0; // timer 的方向记录（切换方向时重新计时）

  // ---------- 拖动垂直自动滚动（时间轴顶部/底部边缘） ----------

  Timer? _autoScrollTimer;

  /// 拖动中检测手指是否接近时间轴视口顶部/底部，触发自动滚动
  /// （如从 22:00 拖到 6:00 需要向上滚动）。
  /// 用 Scrollable 视口的全局位置精确换算：手指在视口内 y =
  /// 全局 y - 视口顶部全局 y（不受 ListView padding/滚动偏移影响）。
  void _checkVerticalAutoScroll(double globalDy) {
    final scroll = widget.scrollController;
    if (scroll == null || !scroll.hasClients) return;
    final scrollable = Scrollable.of(context);
    final scrollBox = scrollable.context.findRenderObject() as RenderBox?;
    if (scrollBox == null || !scrollBox.hasSize) return;
    final viewportTop = scrollBox.localToGlobal(Offset.zero).dy;
    final viewportH = scrollBox.size.height;
    final fingerY = globalDy - viewportTop;
    // 上滑触发区 30px；下滑触发区 90px（底部靠近导航栏，放宽便于触发）
    if (fingerY < 30) {
      _startAutoScroll(-1);
    } else if (fingerY > viewportH - 90) {
      _startAutoScroll(1);
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll(int dir) {
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      final scroll = widget.scrollController;
      if (scroll == null || !scroll.hasClients) return;
      final max = scroll.position.maxScrollExtent;
      final target = (scroll.offset + dir * 8).clamp(0.0, max);
      if (target == scroll.offset) {
        _stopAutoScroll();
        return;
      }
      scroll.jumpTo(target);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _maybeEdgeTurn(double globalX) {
    final onEdgeTurn = widget.onEdgeTurn;
    final state = widget.edgeState;
    if (onEdgeTurn == null || state == null) return;
    final w = MediaQuery.of(context).size.width;
    if (globalX > w * 0.94) {
      if (state.value == 1) return; // 同方向已触发，需回中间
      if (_edgeTimer == null || _edgeDir != 1) {
        _edgeTimer?.cancel();
        _edgeDir = 1;
        _edgeTimer = Timer(const Duration(milliseconds: 300), () {
          _edgeTimer = null;
          state.value = 1;
          onEdgeTurn(1);
        });
      }
    } else if (globalX < w * 0.06) {
      if (state.value == -1) return;
      if (_edgeTimer == null || _edgeDir != -1) {
        _edgeTimer?.cancel();
        _edgeDir = -1;
        _edgeTimer = Timer(const Duration(milliseconds: 300), () {
          _edgeTimer = null;
          state.value = -1;
          onEdgeTurn(-1);
        });
      }
    } else {
      // 离开边缘区：取消计时并重置滞回
      _edgeTimer?.cancel();
      _edgeTimer = null;
      _edgeDir = 0;
      state.value = 0;
    }
  }

  @override
  void dispose() {
    _edgeTimer?.cancel();
    _stopAutoScroll();
    _ghostY.dispose();
    _hintPos.dispose();
    super.dispose();
  }

  /// Draggable 全局坐标驱动（丝滑交互：边缘翻周/日不依赖 DragTarget 命中——
  /// 指针拖出列范围/屏幕边缘空白区仍可靠检测；此前基于 DragTarget.onMove，
  /// 一旦 onLeave 触发即失效）
  void _handleDragGlobal(Offset global) {
    _maybeEdgeTurn(global.dx);
    _checkVerticalAutoScroll(global.dy);
  }

  /// 拖动结束（松手）：统一清理边缘翻页/自动滚动状态（幂等，onAccept 后也会走）
  void _handleDragEnd() {
    _stopAutoScroll();
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgeDir = 0;
    widget.edgeState?.value = 0;
    _ghostY.value = null;
    _hintPos.value = null;
    if (mounted) {
      setState(() {
        _dragTaskId = null;
        _dragY = null;
      });
    }
  }

  /// 是否显示在顶部置顶区（全天 / 无计划时间 / 跨天任务）
  @override
  Widget build(BuildContext context) {
    // 重叠分栏
    final blocks = _layoutOverlap(widget.items);
    final notifier = ref.read(calendarControllerProvider.notifier);
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        _maybeEdgeTurn(details.offset.dx);
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.offset);
        final dy = local.dy;
        if (_dragTaskId == details.data &&
            _dragY != null &&
            (dy - _dragY!).abs() < 4) {
          return; // 微小位移不重建
        }
        // A12：只更新字段 + 虚影通知器，不 setState 整列重建
        _dragTaskId = details.data;
        _dragY = dy;
        _ghostY.value = dy;
        // A13：悬浮时间胶囊跟随手指
        _hintPos.value = Offset(local.dx, dy);
        // 垂直自动滚动：手指接近时间轴视口顶部/底部时滚动
        _checkVerticalAutoScroll(details.offset.dy);
      },
      onLeave: (details) {
        if (_dragTaskId == null) return;
        _stopAutoScroll();
        // 注意：不再取消 _edgeTimer——拖动离开列后指针仍可能停在
        // 屏幕边缘（布局收窄后的边缘区），边缘翻周由 Draggable
        // onDragUpdate 全局坐标继续驱动（_handleDragGlobal）；
        // 松手时由 _handleDragEnd 统一清理
        widget.edgeState?.value = 0; // 重置边缘滞回
        _ghostY.value = null;
        _hintPos.value = null;
        setState(() {
          _dragTaskId = null;
          _dragY = null;
        });
      },
      onAcceptWithDetails: (details) async {
        // 落点局部坐标 → 吸附 10 分钟 → 改期（含时分，支持跨天）
        final box = context.findRenderObject() as RenderBox?;
        var dy = 0.0;
        if (box != null) {
          dy = box.globalToLocal(details.offset).dy;
        }
        final minutes = (widget.startHour * 60 + dy / _pixelPerHour * 60)
            .roundToDouble()
            .clamp(widget.startHour * 60.0, _endHour * 60.0);
        final snapped = ((minutes / 10).round() * 10).clamp(
          widget.startHour * 60,
          _endHour * 60,
        );
        final d = widget.day; // 改期落点 = 落点所在列的真实日期（翻页后为新页列）
        final target = DateTime(
          d.year,
          d.month,
          d.day,
          snapped ~/ 60,
          snapped % 60,
        );
        // 重复任务：确认"整个系列"改期（避免误改）
        final allItems = ref.read(calendarControllerProvider).items;
        CalendarItem? dragged;
        for (final it in allItems) {
          if (it.task.id == details.data) {
            dragged = it;
            break;
          }
        }
        if (dragged != null && dragged.task.rrule.isNotEmpty) {
          if (!mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('更改整个系列？'),
              content: Text(
                '「${dragged!.task.title}」是重复任务。\n'
                '将把整个系列改为从 ${DateUtilsEx.timeCn(target)} 开始'
                '（时长保持不变），旧日期上的完成记录将被清理。\n\n'
                '只想改这一天，请用「跳过本次 / 改期」菜单。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('更改整个系列'),
                ),
              ],
            ),
          );
          if (ok != true) {
            // 取消系列改期：同样清理拖动状态，避免浮标/幽灵块残留

            _stopAutoScroll();
            _edgeTimer?.cancel();
            _edgeTimer = null;
            _edgeDir = 0;
            widget.edgeState?.value = 0; // 重置边缘滞回
            _hintPos.value = null;
            if (mounted) {
              setState(() {
                _dragTaskId = null;
                _dragY = null;
              });
            }
            return;
          }
          await notifier.moveTaskToDateTimeSeries(details.data, target);
          // 拖动结束：清空状态让浮标消失

          _stopAutoScroll();
          _edgeTimer?.cancel();
          _edgeTimer = null;
          _edgeDir = 0;
          widget.edgeState?.value = 0; // 重置边缘滞回
          _ghostY.value = null;
          _hintPos.value = null;
          if (mounted) {
            setState(() {
              _dragTaskId = null;
              _dragY = null;
            });
          }
          if (context.mounted) {
            showAppSnackBar(
              context,
              '已更改整个系列的计划时间',
              actionLabel: '撤销',
              onAction: () => notifier.undoMoveTaskSeries(),
              icon: Icons.event_repeat,
            );
          }
          return;
        }
        await notifier.moveTaskToDateTime(details.data, target);
        // 拖动结束：清空状态让浮标消失

        _stopAutoScroll();
        _edgeTimer?.cancel();
        _edgeTimer = null;
        _edgeDir = 0;
        widget.edgeState?.value = 0; // 重置边缘滞回
        _ghostY.value = null;
        _hintPos.value = null;
        if (mounted) {
          setState(() {
            _dragTaskId = null;
            _dragY = null;
          });
        }
      },
      builder: (context, candidate, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // C6-1：记录点击位置（预填计划时刻，此前点 14:00 却建全天任务）
          onTapDown: (d) => _tapY = d.localPosition.dy,
          onTap: () {
            if (candidate.isNotEmpty) return;
            // 点空白创建：按点击位置预填 1 小时时段（吸附 10 分钟）
            final minutes = widget.startHour * 60 + _tapY / _pixelPerHour * 60;
            final tapped = ((minutes / 10).round() * 10)
                .clamp(widget.startHour * 60, _endHour * 60 - 60)
                .toInt();
            final dayStart = DateTime(
              widget.day.year,
              widget.day.month,
              widget.day.day,
              tapped ~/ 60,
              tapped % 60,
            );
            _openQuickAdd(
              context,
              ref,
              widget.day,
              start: dayStart,
              end: dayStart.add(const Duration(hours: 1)),
            );
          },
          // E7：长按拖动选择时间区间（10 分钟粒度）
          onLongPressStart: (details) {
            if (candidate.isNotEmpty) return;
            Haptics.select();
            _dragFingerY = details.localPosition.dy;
            setState(() {
              _dragSelecting = true;
              _dragStartY = details.localPosition.dy;
              _dragCurrentY = details.localPosition.dy;
            });
            // A13：悬浮时间胶囊跟随手指
            _hintPos.value = Offset(
              details.localPosition.dx,
              details.localPosition.dy,
            );
          },
          onLongPressMoveUpdate: (details) {
            if (!_dragSelecting) return;
            // 边缘自动翻页（选时跨周/跨天）
            _maybeEdgeTurn(details.globalPosition.dx);
            _dragFingerY = details.localPosition.dy;
            // 实时吸附：预览高亮区跟随 10 分钟粒度，松手结果一致
            setState(() {
              final (sy, ey) = _snappedYRange(
                _dragStartY ?? details.localPosition.dy,
                details.localPosition.dy,
              );
              _dragCurrentY = ey;
              _dragStartY = sy;
            });
            // A13：悬浮时间胶囊跟随手指
            _hintPos.value = Offset(
              details.localPosition.dx,
              details.localPosition.dy,
            );
          },
          onLongPressEnd: (_) {
            if (!_dragSelecting) return;
            final start = _dragStartY ?? 0;
            final end = _dragCurrentY ?? start;
            _dragFingerY = null;
            _hintPos.value = null;
            setState(() {
              _dragSelecting = false;
              _dragStartY = null;
              _dragCurrentY = null;
            });
            // P2：长按未拖动（位移过小）→ 等价点击空白，打开默认时长
            // 快速添加（此前有震动但无任何动作）
            if ((end - start).abs() < 20) {
              _openQuickAdd(context, ref, widget.day);
              return;
            }
            final (t1, t2) = _snapRange(start, end);
            _openQuickAddWithRange(
              context,
              ref,
              _targetDay, // 跨页后目标日跟随当前显示日期
              t1,
              t2,
            );
          },
          child: Container(
            height: (_endHour - widget.startHour) * _pixelPerHour,
            // 拖入不整列变蓝（用户反馈太丑），仅保留顶部时间浮标与指示线
            child: Stack(
              // A13：胶囊浮层允许跨列绘制（周视图列宽约 50px，胶囊 78px）
              clipBehavior: Clip.none,
              children: [
                for (final b in blocks)
                  if (b.moreCount > 0)
                    // +N 徽标：紧贴组区间底部外沿下方（原右上角压任务块标题；
                    // 曾误用 bottom 导致钉到整列底部而"消失"）
                    // A10：加 key（按任务实例匹配，避免排序变化后错位滑动）
                    AnimatedPositioned(
                      key: ValueKey('more-${b.item.task.id}-${b.item.instanceDate}'),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      top: (b.spanEnd != null
                              ? _topForSpan(b.spanEnd!)
                              : _topFor(b.item) + _heightFor(b.item)) +
                          2,
                      right: 4,
                      width: 36,
                      height: 18,
                      child: RepaintBoundary(
                        child: _MoreBlock(
                          count: b.moreCount,
                          day: b.item.instanceDate,
                        ),
                      ),
                    )
                  else
                    // A2：拖动改期后任务块从原位置平滑移动到新位置（同列内）
                    // A10：加 key（此前按 index 匹配，改期/增删后"错误的块
                    // 滑到错误位置"，观感像闪烁）
                    AnimatedPositioned(
                      key: ValueKey('blk-${b.item.task.id}-${b.item.instanceDate}'),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      top: _topFor(b.item),
                      left: b.left * (columnWidth / b.total),
                      width: _blockWidth(b),
                      height: _heightFor(b.item),
                      // A13：任务块内容重绘隔离（滚动/动画时复用已绘制层）
                      child: RepaintBoundary(
                        child: _TaskBlock(
                          item: b.item,
                          allDay: false,
                          // 边缘翻周/日 + 垂直自动滚动：Draggable 全局坐标驱动
                          onDragPosition: _handleDragGlobal,
                          onDragEnd: _handleDragEnd,
                        ),
                      ),
                    ),
                // E7：拖动选择高亮区（不透明浅色填充，避免网格线透出形成"双横线"；
                // 内含起止时间，实时变化）
                if (_dragSelecting &&
                    _dragStartY != null &&
                    _dragCurrentY != null)
                  Positioned(
                    top: _dragStartY! < _dragCurrentY!
                        ? _dragStartY!
                        : _dragCurrentY!,
                    height: (_dragStartY! - _dragCurrentY!).abs(),
                    left: 2,
                    right: 2,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        alignment: Alignment.topLeft,
                        child: Text(
                          _selectionHintText(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                // 拖动改期虚影：目标位置实时预览（最上层，跟随手指）
                // A12：ValueListenableBuilder 只重建虚影层（不再整列重建）；
                // A11：AnimatedPositioned 80ms 平滑滑向吸附点（不再 10 分钟步进跳动）
                ValueListenableBuilder<double?>(
                  valueListenable: _ghostY,
                  builder: (context, gy, _) {
                    if (gy == null || _dragTaskId == null) {
                      return const SizedBox.shrink();
                    }
                    return AnimatedPositioned(
                      duration: const Duration(milliseconds: 80),
                      curve: Curves.easeOut,
                      // P1-7：虚影位置 = 实际写入（C5-1 回退后）的开始时间
                      top: _ghostTopFor(gy),
                      left: 2,
                      right: 2,
                      height: (_dragGhostHeight()),
                      child: _dragGhost(),
                    );
                  },
                ),
                // A13：悬浮时间胶囊——跟随手指上方显示当前吸附时间，
                // 防止手指遮挡（拖动改期 + 长按拖选共用；顶部空间不足时翻到手指下方）
                ValueListenableBuilder<Offset?>(
                  valueListenable: _hintPos,
                  builder: (context, pos, _) {
                    final text = _hintTimeText();
                    if (pos == null || text == null) {
                      return const SizedBox.shrink();
                    }
                    const capH = 28.0;
                    const capW = 78.0;
                    final maxY = (_endHour - widget.startHour) * _pixelPerHour;
                    // A13：垂直锚点 = 选区/虚影上端（而非手指位置），
                    // 胶囊始终在任务块上方，不遮挡选区内容
                    final double anchorY;
                    if (_dragSelecting && _dragStartY != null) {
                      anchorY = _dragStartY!; // move 后已写回吸附后的选区上端
                    } else if (_dragTaskId != null && _dragY != null) {
                      // P1-7：胶囊锚点 = 实际写入（回退后）的开始时间位置
                      final gStart =
                          _draggedStartForMinutes(_snapMinutesForY(_dragY!));
                      anchorY = ((gStart.hour * 60 + gStart.minute) -
                                  widget.startHour * 60) /
                              60 *
                              _pixelPerHour;
                    } else {
                      return const SizedBox.shrink();
                    }
                    var top = anchorY - capH - 12;
                    if (top < 4) top = anchorY + 12; // 顶部空间不足 → 贴选区上端下方
                    top = top.clamp(4.0, maxY - capH - 4);
                    // A13：水平按整个时间轴视口宽 clamp（周视图单列仅约 50px，
                    // 按列 clamp 会因 min>max 抛 ArgumentError 使整列崩溃；
                    // 胶囊是浮层，允许跨列绘制）。
                    // 列内 Positioned 坐标换算：视口内位置 = viewportLeft + 列内 dx，
                    // 先钳制在视口内再减回列偏移——周日列胶囊右缘不再超出视口被裁
                    final viewportW = columnWidth * (widget.isWeek ? 7 : 1);
                    final left =
                        (widget.viewportLeft + pos.dx - capW / 2).clamp(
                              4.0,
                              viewportW - capW - 4,
                            ) -
                        widget.viewportLeft;
                    final scheme = Theme.of(context).colorScheme;
                    return Positioned(
                      top: top,
                      left: left,
                      width: capW,
                      child: IgnorePointer(
                        child: Container(
                          height: capH,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: scheme.inverseSurface,
                            borderRadius: BorderRadius.circular(capH / 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            // 防溢出：Ahem 测试字体/系统大字体下 5 字符时间
                            // 可超过胶囊可用宽，Flexible+ellipsis 兜底
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.schedule,
                                size: 13,
                                color: scheme.onInverseSurface,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onInverseSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 拖动改期虚影：目标位置实时预览（半透明任务块 + 标题 + 时间）
  Widget _dragGhost() {
    final draggingId = _dragTaskId;
    final dragY = _dragY;
    if (draggingId == null || dragY == null) return const SizedBox.shrink();
    final itemsAll = ref.read(calendarControllerProvider).items;
    CalendarItem? dragged;
    for (final it in itemsAll) {
      if (it.task.id == draggingId) {
        dragged = it;
        break;
      }
    }
    if (dragged == null) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final color =
        TaskColors.colorOf(dragged.task.color, brightness) ??
        colorFromHex(dragged.listColor);
    final onColor = TaskColors.textOn(color);
    final snapped = _snapMinutesForY(dragY);
    // P1-7：虚影显示实际写入的开始时间（C5-1 回退后），所见即所得
    final start = _draggedStartForMinutes(snapped);
    final dur = dragged.task.durationMinutes;
    final end = start.add(Duration(minutes: dur));
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          // 高不透明度保证深色主题下清晰可见
          color: color.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.7),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dragged.task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: onColor,
              ),
            ),
            Text(
              '${DateUtilsEx.timeCn(start)} - ${DateUtilsEx.timeCn(end)}',
              style: TextStyle(
                fontSize: 9,
                color: onColor.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// y 坐标吸附后的分钟数（10 分钟粒度）
  int _snapMinutesForY(double y) {
    final minutes = (widget.startHour * 60 + y / _pixelPerHour * 60)
        .roundToDouble()
        .clamp(widget.startHour * 60.0, _endHour * 60.0);
    return ((minutes / 10).round() * 10)
        .clamp(widget.startHour * 60, _endHour * 60)
        .round();
  }

  /// 虚影高度（被拖任务时长对应；不足 30 分钟按 30 分钟，与实块一致）
  double _dragGhostHeight() {
    final draggingId = _dragTaskId;
    if (draggingId == null) return _pixelPerHour;
    final itemsAll = ref.read(calendarControllerProvider).items;
    for (final it in itemsAll) {
      if (it.task.id == draggingId) {
        final h = it.task.durationMinutes / 60 * _pixelPerHour;
        return h < 32 ? 32 : h;
      }
    }
    return _pixelPerHour;
  }

  /// P1-7：拖动改期虚影的实际开始时间——落点分钟经 C5-1"时长不跨天"
  /// 回退后（22:30 拖 2h 任务实际写入 21:00），预览（虚影/胶囊）与
  /// 写入端 moveTaskToDateTime 必须一致，否则所见非所得。
  DateTime _draggedStartForMinutes(int minutes) {
    final durMin = _draggedDurationMinutes() ?? 60;
    return DateUtilsEx.clampStartWithinDay(
      DateTime(
        widget.day.year,
        widget.day.month,
        widget.day.day,
        minutes ~/ 60,
        minutes % 60,
      ),
      Duration(minutes: durMin),
    );
  }

  int? _draggedDurationMinutes() {
    final draggingId = _dragTaskId;
    if (draggingId == null) return null;
    final itemsAll = ref.read(calendarControllerProvider).items;
    for (final it in itemsAll) {
      if (it.task.id == draggingId) return it.task.durationMinutes;
    }
    return null;
  }

  /// P1-7：虚影在时间轴内的 top——基于实际写入（C5-1 回退后）的开始时间
  double _ghostTopFor(double gy) {
    final s = _draggedStartForMinutes(_snapMinutesForY(gy));
    return ((s.hour * 60 + s.minute) - widget.startHour * 60) /
            60 *
            _pixelPerHour -
        1;
  }

  /// E7：将拖动范围吸附到 10 分钟粒度
  /// P2：与 _snappedYRange 一致 clamp 到 [06:00, 23:00]——
  /// 此前顶部/底部 padding 区拖动可得 5:30/23:30，预览与结果不一致
  /// C5-2：两端同 clamp 到 23:00 时保证至少 10 分钟跨度
  (DateTime, DateTime) _snapRange(double y1, double y2) {
    final minutes1 = widget.startHour * 60 + (y1 < y2 ? y1 : y2) / _pixelPerHour * 60;
    final minutes2 = widget.startHour * 60 + (y1 < y2 ? y2 : y1) / _pixelPerHour * 60;
    var snapped1 = ((minutes1 / 10).round() * 10)
        .clamp(widget.startHour * 60, _endHour * 60)
        .toInt();
    final snapped2 = ((minutes2 / 10).round() * 10)
        .clamp(widget.startHour * 60, _endHour * 60)
        .toInt();
    // 两端相等（拖到底部边界）→ 起点回退 10 分钟
    if (snapped2 <= snapped1) {
      snapped1 = (snapped2 - 10).clamp(widget.startHour * 60, _endHour * 60);
    }
    final d = _targetDay;
    return (
      DateTime(d.year, d.month, d.day, snapped1 ~/ 60, snapped1 % 60),
      DateTime(d.year, d.month, d.day, snapped2 ~/ 60, snapped2 % 60),
    );
  }

  /// 将 y 坐标区间吸附到 10 分钟粒度（预览高亮区用，与 _snapRange 一致）
  (double, double) _snappedYRange(double y1, double y2) {
    double snap(double y) {
      final minutes = widget.startHour * 60 + y / _pixelPerHour * 60;
      final snapped = ((minutes / 10).round() * 10).clamp(
        widget.startHour * 60,
        _endHour * 60,
      );
      return (snapped - widget.startHour * 60) / 60 * _pixelPerHour;
    }

    final s1 = snap(y1 < y2 ? y1 : y2);
    final s2 = snap(y1 < y2 ? y2 : y1);
    return (s1, s2);
  }

  /// 拖动选时创建：当前选区的时间文字（跟随手指）
  String _selectionHintText() {
    final s = _dragStartY ?? 0;
    final e = _dragCurrentY ?? s;
    final (t1, t2) = _snapRange(s, e);
    return '${DateUtilsEx.timeCn(t1)} - ${DateUtilsEx.timeCn(t2)}';
  }

  /// A13：悬浮时间胶囊文本（单时间，防遮挡）：
  /// - 拖动改期：实际写入的开始时间（C5-1 回退后，P1-7 与写入一致）
  /// - 长按拖选：手指所指的实时时间（_dragFingerY，向上/向下拖都指哪显示哪）
  String? _hintTimeText() {
    if (_dragSelecting && _dragFingerY != null) {
      final minutes = _snapMinutesForY(_dragFingerY!);
      return DateUtilsEx.timeCn(
        DateTime(
          widget.day.year,
          widget.day.month,
          widget.day.day,
          minutes ~/ 60,
          minutes % 60,
        ),
      );
    }
    if (_dragTaskId != null && _dragY != null) {
      return DateUtilsEx.timeCn(
        _draggedStartForMinutes(_snapMinutesForY(_dragY!)),
      );
    }
    return null;
  }

  /// C6-1：点空白位置（预填计划时刻用）
  double _tapY = 0;

  void _openQuickAdd(
    BuildContext context,
    WidgetRef ref,
    DateTime day, {
    DateTime? start,
    DateTime? end,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => QuickAddSheetWithDefaults(
        day,
        start: start,
        end: end,
      ),
    );
  }

  void _openQuickAddWithRange(
    BuildContext context,
    WidgetRef ref,
    DateTime day,
    DateTime s,
    DateTime e,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => QuickAddSheetWithRange(start: s, end: e),
    );
  }

  /// 任务块顶部位置：例外改期目标时刻（displayTime）优先，否则 planStart 时分
  double _topFor(CalendarItem item) {
    final dt = item.displayTime;
    final ps = item.task.planStart;
    final minutes = dt != null
        ? dt.hour * 60 + dt.minute
        : (ps?.hour ?? 0) * 60 + (ps?.minute ?? 0);
    return (minutes - widget.startHour * 60) / 60 * _pixelPerHour;
  }

  double _heightFor(CalendarItem item) {
    final dur = item.task.durationMinutes;
    final h = dur / 60 * _pixelPerHour;
    // A13：不足 30 分钟的任务按 30 分钟（32px）显示，保证块内文字可读
    return h < 32 ? 32 : h;
  }

  /// 组区间 y 坐标换算（+N 徽标定位用）
  double _topForSpan(DateTime s) {
    final minutes = s.hour * 60 + s.minute;
    return (minutes - widget.startHour * 60) / 60 * _pixelPerHour;
  }

  double _blockWidth(OverlapBlock b) {
    // 平分宽度，块间留 2px 间隙（单任务时几乎填满整列）
    return columnWidth / b.total - 2;
  }

  /// 重叠任务分栏：同一时间最多显示 2 个任务块，其余合并为「+N」徽标。
  /// 互相重叠的任务按传递闭包分组（并查集）；组内 ≤2 平分列宽，>2 时
  /// 前 2 个分栏 + 1 个「+N」徽标（组区间右上角，点击弹当天任务列表）。
  /// 区间按"实例日期时分"计算（重复任务实例与其他任务正确重叠）。
  List<OverlapBlock> _layoutOverlap(List<CalendarItem> items) {
    final sorted = List<CalendarItem>.from(items)
      ..sort(
        (a, b) => (a.displayTime ?? a.task.planStart)!.compareTo(
          b.displayTime ?? b.task.planStart!,
        ),
      );
    final intervals = <_Interval>[];
    for (final i in sorted) {
      final ps = i.task.planStart;
      final pe = i.task.planEnd;
      final day = i.instanceDate;
      // P1-B：例外改期目标时刻（displayTime）优先，否则 planStart 时分
      final dt = i.displayTime;
      final s = ps == null
          ? DateTime(day.year, day.month, day.day)
          : dt != null
          ? DateTime(
              day.year,
              day.month,
              day.day,
              dt.hour,
              dt.minute,
            )
          : DateTime(day.year, day.month, day.day, ps.hour, ps.minute);
      final endTime = pe ?? ps?.add(const Duration(hours: 1));
      var e = endTime == null
          ? s.add(const Duration(hours: 1))
          : dt != null
          ? s.add(endTime.difference(ps ?? endTime))
          : DateTime(
              day.year,
              day.month,
              day.day,
              endTime.hour,
              endTime.minute,
            );
      if (e.isBefore(s)) e = e.add(const Duration(days: 1)); // 跨天（22:00-02:00）
      intervals.add(_Interval(s, e));
    }
    final n = intervals.length;
    if (n == 0) return const [];

    // 并查集：互相重叠的任务归为一组（传递闭包）
    final parent = List<int>.generate(n, (i) => i);
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      parent[find(a)] = find(b);
    }

    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if (_overlaps(
          intervals[i].start,
          intervals[i].end,
          intervals[j].start,
          intervals[j].end,
        )) {
          union(i, j);
        }
      }
    }
    final groups = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      groups.putIfAbsent(find(i), () => []).add(i);
    }

    final result = <OverlapBlock>[];
    for (final members in groups.values) {
      // 组内并集区间（+N 块用）
      var minStart = intervals[members.first].start;
      var maxEnd = intervals[members.first].end;
      for (final i in members) {
        if (intervals[i].start.isBefore(minStart)) minStart = intervals[i].start;
        if (intervals[i].end.isAfter(maxEnd)) maxEnd = intervals[i].end;
      }
      if (members.length <= 2) {
        var col = 0;
        for (final i in members) {
          result.add(
            OverlapBlock(
              item: sorted[i],
              left: col,
              total: members.length,
            ),
          );
          col++;
        }
      } else {
        // 超过 2 个：前 2 个分栏，其余合并为 +N 块
        var col = 0;
        for (final i in members.take(2)) {
          result.add(OverlapBlock(item: sorted[i], left: col, total: 2));
          col++;
        }
        result.add(
          OverlapBlock(
            item: sorted[members.first],
            left: 0,
            total: 1,
            moreCount: members.length - 2,
            spanStart: minStart,
            spanEnd: maxEnd,
          ),
        );
      }
    }
    return result;
  }

  bool _overlaps(DateTime a1, DateTime a2, DateTime b1, DateTime b2) =>
      a1.isBefore(b2) && b1.isBefore(a2);
}

class _Interval {
  final DateTime start;
  final DateTime end;

  _Interval(this.start, this.end);
}

class OverlapBlock {
  final CalendarItem item;
  final int left;
  final int total;
  /// >0 表示这是「+N」折叠块（N=moreCount，区间用 spanStart）
  final int moreCount;
  final DateTime? spanStart;
  /// A13：+N 块组并集区间终点（徽标定位到组区间底部外沿用）
  final DateTime? spanEnd;

  OverlapBlock({
    required this.item,
    required this.left,
    required this.total,
    this.moreCount = 0,
    this.spanStart,
    this.spanEnd,
  });
}

/// 「+N」小徽标：同一时间超过 2 个任务时的提示，点击弹当天任务列表
class _MoreBlock extends StatelessWidget {
  const _MoreBlock({required this.count, required this.day});

  final int count;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (c) => DayPreviewSheet(day: day),
          );
        },
        child: Center(
          child: Text(
            '+$count',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// 任务块（可拖动改期、长按菜单、点击详情、勾选完成）
class _TaskBlock extends ConsumerWidget {
  const _TaskBlock({
    required this.item,
    required this.allDay,
    this.showTime = false,
    this.onDragPosition,
    this.onDragEnd,
  });

  final CalendarItem item;
  final bool allDay;
  /// C3-4：置顶区跨天任务显示起止时刻小字
  final bool showTime;
  /// 拖动中全局指针位置上报（边缘翻周/日检测用——Draggable 全局坐标
  /// 不依赖 DragTarget 命中，指针拖出列/屏幕边缘仍可靠）
  final ValueChanged<Offset>? onDragPosition;
  /// 拖动结束（松手）回调：清理边缘/自动滚动状态
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(calendarControllerProvider.notifier);
    final done = item.completed;
    final brightness = Theme.of(context).brightness;
    // 主体色：任务色优先，未设置回退清单色（D1 决策）
    final baseColor =
        TaskColors.colorOf(item.task.color, brightness) ??
        colorFromHex(item.listColor);
    final color = done ? Colors.grey : baseColor;
    final block = _blockBody(context, color, done, notifier, ref);
    // 全天任务：禁止拖入时间轴（保持全天语义），仅保留点击操作
    if (allDay) return block;
    return LongPressDraggable<int>(
      data: item.task.id,
      onDragStarted: () => Haptics.select(),
      // 边缘翻周/日：Draggable 全局坐标驱动（此前依赖 DragTarget.onMove，
      // 指针离开列范围即失效）
      onDragUpdate: (d) => onDragPosition?.call(d.globalPosition),
      onDragEnd: (_) => onDragEnd?.call(),
      // 拖动不显示悬浮块：目标位置由虚影（_dragGhost）实时预览
      feedback: Material(
        color: Colors.transparent,
        child: const SizedBox.shrink(),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: block,
      ),
      child: block,
    );
  }

  Widget _blockBody(
    BuildContext context,
    Color color,
    bool done,
    dynamic notifier,
    WidgetRef ref,
  ) {
    final t = item.task;
    final listColor = colorFromHex(item.listColor);
    final onColor = TaskColors.textOn(color);
    // 完成态：整体不明显的灰色
    // 实心背景：半透明会让时间网格线透出形成"横线"观感（黄色任务尤其明显）
    // B5：完成态用主题表面色（此前 grey.shade300/500 在暗色下"亮一块"）
    final scheme = Theme.of(context).colorScheme;
    final bgColor = done ? scheme.surfaceContainerHighest : color;
    final textColor = done ? scheme.onSurfaceVariant : onColor;
    final accentColor = done ? scheme.outline : listColor;
    const radius = 6.0;
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        // 点击弹出实例操作层（完成/跳过/改期本次/详情）
        onTap: () {
          showModalBottomSheet(
            context: context,
            builder: (c) => InstanceActionSheet(item: item),
          );
        },
        // 长按交给 LongPressDraggable 拖动改期，不弹菜单
        child: Stack(
          children: [
            // 清单色线：紧贴块左边缘，上下避开圆角（与左边直边同高）
            Positioned(
              left: 0,
              top: radius,
              bottom: radius,
              child: Container(width: 1, color: accentColor),
            ),
            Padding(
              // 左侧让出 4px 给色线
              padding: const EdgeInsets.only(
                left: 4,
                right: 2,
                top: 2,
                bottom: 2,
              ),
              child: Row(
                children: [
                  // 文字按块高自适应换行（10px 字约 14dp 行高），只显示标题
                  Expanded(
                    // C3-4：跨天定时任务（置顶区）显示起止时刻小字
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t.title,
                          maxLines: allDay ? 2 : (_blockLineCount()),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            decoration: done
                                ? TextDecoration.lineThrough
                                : null,
                            color: textColor,
                          ),
                        ),
                        if (showTime)
                          Text(
                            '${DateUtilsEx.timeCn(t.planStart!)}-'
                            '${DateUtilsEx.timeCn(t.planEnd ?? t.planStart!.add(const Duration(hours: 1)))}',
                            style: TextStyle(
                              fontSize: 8,
                              color: textColor.withValues(alpha: 0.85),
                            ),
                          ),
                      ],
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

  /// 按块高计算可显示的文字行数（10px 字约 14dp 行高）
  int _blockLineCount() {
    final ps = item.task.planStart;
    final pe = item.task.planEnd;
    if (ps == null) return 2;
    final durMinutes = pe == null
        ? 60
        : pe.difference(ps).inMinutes.clamp(1, 1440);
    final heightDp = durMinutes / 60 * _pixelPerHour;
    final lines = (heightDp / 14).floor();
    return lines.clamp(1, 3);
  }
}

/// 实例操作弹层（周/日视图任务块点击弹出；月视图经日预览弹层）
class InstanceActionSheet extends ConsumerStatefulWidget {
  const InstanceActionSheet({super.key, required this.item});

  final CalendarItem item;

  @override
  ConsumerState<InstanceActionSheet> createState() =>
      _InstanceActionSheetState();
}

class _InstanceActionSheetState extends ConsumerState<InstanceActionSheet> {
  /// 例外改期：实例日 → 改期目标时刻（5.3：弹层字幕显示改期后的时间）
  DateTime? _rescheduledTo;

  CalendarItem get item => widget.item;

  @override
  void initState() {
    super.initState();
    _loadException();
  }

  Future<void> _loadException() async {
    final db = ref.read(dbProvider);
    final exs = await db.getExceptions(item.task.id);
    for (final ex in exs) {
      final od = ex.overrideScheduledDate;
      if (ex.action == 'edit' &&
          od != null &&
          DateUtilsEx.sameDay(od, item.instanceDate)) {
        if (mounted) {
          setState(() => _rescheduledTo = od);
        }
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(calendarControllerProvider.notifier);
    final t = item.task;
    final day = item.instanceDate;
    // 5.3：被例外改期到的实例显示目标时刻（原 planStart 已不再准确）
    final displayTime = _rescheduledTo ?? t.planStart;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${DateUtilsEx.dateCn(day)}'
              '${t.rrule.isNotEmpty ? '（本次实例）' : ''}'
              '${t.isAllDay ? '' : ' · ${DateUtilsEx.timeCn(displayTime ?? day)}'}',
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              item.completed ? Icons.undo : Icons.check_circle_outline,
            ),
            title: Text(item.completed ? '撤销完成本次' : '完成本次'),
            onTap: () {
              Navigator.pop(context);
              notifier.toggleComplete(item);
            },
          ),
          if (t.rrule.isNotEmpty) ...[
            ListTile(
              leading: const Icon(Icons.skip_next),
              title: const Text('跳过本次'),
              onTap: () async {
                // P1-D：先等待跳过写入完成，再弹撤销条（此前先弹条后
                // fire-and-forget 执行，快速点撤销读到旧 skippedDates 会静默失效）
                await notifier.skipInstance(t.id, day);
                if (!mounted) return;
                showAppSnackBar(
                  this.context,
                  '已跳过 ${DateUtilsEx.dateCn(day)} 的实例',
                  actionLabel: '撤销',
                  onAction: () => notifier.unskipInstance(t.id, day),
                  icon: Icons.skip_next,
                );
                Navigator.pop(this.context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.event_repeat),
              title: const Text('改期本次'),
              onTap: () => _pickReschedule(ref, item),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('查看详情'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TaskDetailPage(taskId: t.id),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 改期本次（日期 + 时间；撤销=删除例外恢复原日期）
  Future<void> _pickReschedule(WidgetRef ref, CalendarItem item) async {
    final now = AppClock.now();
    final ps = item.task.planStart;
    // P1-7：日视图可翻到百年前，实例日期超界会触发 DatePicker 断言崩溃
    final first = DateTime(now.year - 1);
    final last = DateTime(now.year + 5);
    final initial = item.instanceDate;
    final clamped = initial.isBefore(first)
        ? first
        : (initial.isAfter(last) ? last : initial);
    final picked = await showDatePicker(
      context: context,
      initialDate: clamped,
      firstDate: first,
      lastDate: last,
      helpText: '改期本次到',
    );
    if (picked == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: ps?.hour ?? 9, minute: ps?.minute ?? 0),
      helpText: '选择实例时间',
    );
    if (pickedTime == null || !mounted) return;
    final toDate = DateTime(
      picked.year,
      picked.month,
      picked.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    final tasksNotifier = ref.read(tasksControllerProvider.notifier);
    // P0-3.3：记录例外 ID，撤销时删除该例外（而非新增反向例外）
    final exId = await tasksNotifier.editException(
      item.task.id,
      item.instanceDate,
      toDate,
    );
    if (!mounted) return;
    showAppSnackBar(
      context,
      '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
      actionLabel: '撤销',
      onAction: () {
        tasksNotifier.undoEditException(item.task.id, exId);
      },
      icon: Icons.event_repeat,
    );
  }
}

/// 月视图日期预览层（完整可操作）
class DayPreviewSheet extends ConsumerStatefulWidget {
  const DayPreviewSheet({super.key, required this.day});

  final DateTime day;

  @override
  ConsumerState<DayPreviewSheet> createState() => _DayPreviewSheetState();
}

class _DayPreviewSheetState extends ConsumerState<DayPreviewSheet> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(calendarControllerProvider);
    final notifier = ref.read(calendarControllerProvider.notifier);
    final dayItems =
        state.items
            .where((i) => DateUtilsEx.sameDay(i.instanceDate, widget.day))
            .toList()
          ..sort((a, b) {
            final at = a.task.planStart;
            final bt = b.task.planStart;
            if (at == null && bt == null) return 0;
            if (at == null) return 1;
            if (bt == null) return -1;
            return at.compareTo(bt);
          });
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                DateUtilsEx.dateCn(widget.day),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (dayItems.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '当天没有任务',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    )
                  else
                    for (final item in dayItems)
                      ListTile(
                        dense: true,
                        // 完成态：不明显的灰色
                        tileColor: item.completed ? Theme.of(context).colorScheme.surfaceContainerHighest : null,
                        leading: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            item.completed
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: item.completed ? Colors.grey.shade400 : null,
                          ),
                          onPressed: () => notifier.toggleComplete(item),
                        ),
                        title: Text(
                          item.task.title,
                          style: TextStyle(
                            color: item.completed ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                            decoration: item.completed
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          item.task.isAllDay || item.task.planStart == null
                              ? '全天'
                              : '${DateUtilsEx.timeCn(item.displayTime ?? item.task.planStart!)} · '
                                    '${_listNameOf(context, item.task.listId)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        // B3：重复任务实例可跳过本次/改期
                        trailing: item.task.rrule.isNotEmpty
                            ? PopupMenuButton<String>(
                                onSelected: (v) =>
                                    _handleInstanceAction(item, v),
                                itemBuilder: (c) => const [
                                  PopupMenuItem(
                                    value: 'skip',
                                    child: Text('跳过本次'),
                                  ),
                                  PopupMenuItem(
                                    value: 'reschedule',
                                    child: Text('改期'),
                                  ),
                                ],
                              )
                            : null,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  TaskDetailPage(taskId: item.task.id),
                            ),
                          );
                        },
                      ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加任务'),
              onTap: () {
                Navigator.pop(context);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (c) => QuickAddSheetWithDefaults(widget.day),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// B3：重复任务实例操作（跳过本次 / 改期到其他日期）
  Future<void> _handleInstanceAction(CalendarItem item, String action) async {
    final notifier = ref.read(calendarControllerProvider.notifier);
    if (action == 'skip') {
      await notifier.skipInstance(item.task.id, item.instanceDate);
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已跳过 ${DateUtilsEx.dateCn(item.instanceDate)} 的实例',
        actionLabel: '撤销',
        onAction: () =>
            notifier.unskipInstance(item.task.id, item.instanceDate),
        icon: Icons.skip_next,
      );
      return;
    }
    if (action == 'reschedule') {
      final now = AppClock.now();
      final ps = item.task.planStart;
      // P1-7：月视图可翻到很久以前，实例日期超界会触发 DatePicker 断言崩溃
      final first = DateTime(now.year - 1);
      final last = DateTime(now.year + 5);
      final initial = item.instanceDate;
      final clamped = initial.isBefore(first)
          ? first
          : (initial.isAfter(last) ? last : initial);
      final picked = await showDatePicker(
        context: context,
        initialDate: clamped,
        firstDate: first,
        lastDate: last,
        helpText: '改期到',
      );
      if (picked == null || !mounted) return;
      // P2：与弹层入口一致——改期保留/选择时分（此前只选日期丢时分，
      // 且更新既有例外时会覆盖之前带时分的改期）
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
          hour: ps?.hour ?? 9,
          minute: ps?.minute ?? 0,
        ),
        helpText: '选择实例时间',
      );
      if (pickedTime == null || !mounted) return;
      final toDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        pickedTime.hour,
        pickedTime.minute,
      );
      // 经任务控制器写入例外，并触发数据版本刷新（日历自动重载）
      final tasksNotifier = ref.read(tasksControllerProvider.notifier);
      final exId = await tasksNotifier.editException(
        item.task.id,
        item.instanceDate,
        toDate,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
        actionLabel: '撤销',
        onAction: () => tasksNotifier.undoEditException(item.task.id, exId),
        icon: Icons.event_repeat,
      );
    }
  }

  String _listNameOf(BuildContext context, int listId) {
    final lists = ref.read(tasksControllerProvider).lists;
    final l = lists.where((e) => e.id == listId).firstOrNull;
    return l?.name ?? '';
  }
}

