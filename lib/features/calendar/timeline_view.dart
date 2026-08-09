import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/features/calendar/calendar_axis.dart';
import 'package:zhuoluo/features/calendar/day_column.dart';

/// 时间轴起始小时——显示范围内最早 timed 任务（非全天/非跨天/
/// 有计划时间）的开始小时，与默认值取小：只扩展不收缩，多数情况保持
/// 06:00 起点；有 06:00 前任务时起始点下移，任务不再隐形不可操作。
/// 丝滑翻页：改为按天分组数据驱动——此前遍历整个窗口 items
/// （每次 build O(N×7)），现只扫显示范围内 7 天。
int effectiveStartHourFor({
  required Map<int, List<CalendarItem>> byDay,
  required List<DateTime> days,
  int defaultStart = startHour,
}) {
  var earliest = defaultStart;
  for (final d in days) {
    for (final it in byDay[dayKey(d)] ?? const <CalendarItem>[]) {
      if (AllDayBar.isTopArea(it)) continue;
      // ：planStart 为 DB 读回值，取字段前按应用时区解释
      final ps = it.task.planStart;
      final h = ps == null ? defaultStart : AppClock.asApp(ps).hour;
      if (h < earliest) earliest = h;
    }
  }
  return earliest;
}


class AxisKeepAlive extends StatefulWidget {
  const AxisKeepAlive({
    super.key,required this.child});

  final Widget child;

  @override
  State<AxisKeepAlive> createState() => AxisKeepAliveState();
}

class AxisKeepAliveState extends State<AxisKeepAlive>
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


class TimeAxisView extends ConsumerStatefulWidget {
  const TimeAxisView({
    super.key,
    required this.pageIndex,
    required this.activePage,
    required this.items,
    required this.byDay,
    required this.start,
    required this.isWeek,
    required this.selectedDay,
    this.dragDay,
    this.edgeState,
    this.scrollOffsetShare,
    this.onEdgeTurn,
    this.dragGlobalPos,
    this.dragTaskId,
    this.dragActiveDay,
    this.dragGhostInfo,
    this.dragDropped,
    this.dragAxisTopY,
    this.dragScrollCtrl,
    this.dragViewportTopY,
    this.dragViewportH,
    this.edgeTurnCtrl,
    this.onDragStartTracking,
  });

  final int pageIndex;
  final ValueNotifier<int> activePage;
  final List<CalendarItem> items;

  /// 按天分组索引（build 不再全窗口扫描）
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

  /// 共享拖拽状态（WeekView/DayView 持有，翻页后新列据此恢复虚影/胶囊）
  final ValueNotifier<Offset?>? dragGlobalPos;
  final ValueNotifier<int?>? dragTaskId;
  final ValueNotifier<DateTime?>? dragActiveDay;
  final ValueNotifier<DragGhostInfo?>? dragGhostInfo;
  final ValueNotifier<bool>? dragDropped;

  /// 本页时间轴主体顶部全局 y 上报（落点兜底换算基准）
  final ValueNotifier<double>? dragAxisTopY;

  /// 本页 scrollController + 视口顶全局 y + 视口高上报（翻页后
  /// Draggable evict 时全局 route 接管垂直自动滚动用）
  final ValueNotifier<ScrollController?>? dragScrollCtrl;
  final ValueNotifier<double>? dragViewportTopY;
  final ValueNotifier<double>? dragViewportH;

  /// 共享边缘翻页控制器（连续翻周链跨页保持）
  final EdgeTurnController? edgeTurnCtrl;

  /// 拖动开始上报指针（WeekView/DayView 注册全局 route 用）
  final void Function(int taskId, int pointer)? onDragStartTracking;

  @override
  ConsumerState<TimeAxisView> createState() => TimeAxisViewState();
}

class TimeAxisViewState extends ConsumerState<TimeAxisView> {
  final _scrollController = ScrollController();
  final _timeBarController = ScrollController();

  /// 本页时间轴主体 Stack 的 key（落点基准上报用，每页独立）
  final GlobalKey _axisKey = GlobalKey();
  bool _restoreScheduled = false;
  int _restoreAttempts = 0;

  @override
  void initState() {
    super.initState();
    // E5：右侧内容滚动 → 左侧时间栏同步跟随 + 更新共享滚动位置
    _scrollController.addListener(_onScroll);
    // 不自动定位到当前时间：任何自动滚动都会在切换周/日、拖动改期时
    // 造成视觉跳变。时间轴位置完全由用户控制。
    // 翻页后新页继承共享滚动位置（切周/切日不跳回顶部）
    widget.activePage.addListener(_onActivePageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreSharedScroll();
    });
    // A7：移除每分钟整页 setState 的时钟 Timer——红线改由独立组件
    // NowLine 自驱动，不再触发整个时间轴重建
  }

  bool get _isActivePage => widget.activePage.value == widget.pageIndex;

  void _onActivePageChanged() {
    if (!mounted) return;
    if (!_isActivePage) {
      // 当前页切走后，禁止全局拖动路由继续操作旧页控制器。
      if (widget.dragScrollCtrl?.value == _scrollController) {
        widget.dragScrollCtrl?.value = null;
      }
      return;
    }
    _restoreAttempts = 0;
    _scheduleRestore();
  }

  void _scheduleRestore() {
    if (_restoreScheduled || !mounted) return;
    _restoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreScheduled = false;
      if (mounted) _restoreSharedScroll();
    });
  }

  void _restoreSharedScroll() {
    if (!_isActivePage) return;
    final share = widget.scrollOffsetShare;
    if (share == null || share.value <= 0) {
      _reportAxisTopY();
      _reportScrollViewport();
      return;
    }
    if (!_scrollController.hasClients) {
      if (_restoreAttempts++ < 4) _scheduleRestore();
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    if (max == 0 && _restoreAttempts++ < 4) {
      _scheduleRestore();
      return;
    }
    _restoreAttempts = 0;
    final target = share.value.clamp(0.0, max).toDouble();
    if ((_scrollController.offset - target).abs() > 0.5) {
      _scrollController.jumpTo(target);
    }
    // 上报当前页基准和控制器，避免翻页后仍使用旧页的坐标/滚动对象。
    _reportAxisTopY();
    _reportScrollViewport();
  }

  /// 本页时间轴主体顶部全局 y（post-frame 布局完成后；滚动时由 _onScroll
  /// 按 offset 修正）。落点兜底（WeekView._handleDragDrop）换算用
  void _reportAxisTopY() {
    final top = widget.dragAxisTopY;
    if (top == null) return;
    final box = _axisKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _baseAxisTopY = box.localToGlobal(Offset.zero).dy;
    _baseAxisOffset = _scrollController.offset;
    top.value = _baseAxisTopY!;
  }

  void _onScroll() {
    _syncTimeBar();
    // 滚动位置同步到共享值（翻页后新页继承）。
    // 防污染：页面重建时 ScrollPosition attach 会触发一次 offset=0 的
    // 伪事件——跳过它（否则共享位置被写 0，新页 post-frame 恢复逻辑
    // `if (share > 0)` 读到 0 不恢复 → 时间轴跳回顶部）
    final share = widget.scrollOffsetShare;
    if (share != null && _isActivePage) {
      final off = _scrollController.offset;
      if (off > 0 || (off - _lastSharedOffset).abs() > 0.5) {
        _lastSharedOffset = off;
        share.value = off;
      }
    }
    // 落点基准随滚动修正（时间轴主体在 ListView 内随内容移动）
    final top = widget.dragAxisTopY;
    if (top != null && _baseAxisTopY != null) {
      top.value = _baseAxisTopY! - (_scrollController.offset - _baseAxisOffset);
    }
  }

  double? _baseAxisTopY;
  double _baseAxisOffset = 0;

  /// 上次写入共享滚动位置的值（_onScroll 防污染用）
  double _lastSharedOffset = 0;

  /// 本页时间轴 ListView 的 scrollController + 视口顶全局 y + 视口高上报
  ///（post-frame；当前页最后写入——翻页后 Draggable evict 时全局 route
  /// 用这些值继续驱动垂直自动滚动）。
  /// 视口取自本页 ListView 自身的 Scrollable（position.context——
  /// Scrollable.of(context) 会找到 PageView 而非时间轴 ListView）
  void _reportScrollViewport() {
    final ctrl = widget.dragScrollCtrl;
    if (ctrl == null) return;
    if (!_isActivePage) return;
    if (!_scrollController.hasClients) return;
    ctrl.value = _scrollController;
    final ctx = _scrollController.position.context.notificationContext;
    final scrollable = ctx?.findRenderObject() as RenderBox?;
    if (scrollable != null && scrollable.hasSize) {
      widget.dragViewportTopY?.value = scrollable.localToGlobal(Offset.zero).dy;
      widget.dragViewportH?.value = scrollable.size.height;
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
    // 页面 State 销毁（如 PageView GC/keepalive 重建）前把本页滚动位置
    // 写回共享值——重建后 post-frame 据此恢复，时间轴不跳回顶部
    widget.activePage.removeListener(_onActivePageChanged);
    if (_isActivePage && _scrollController.hasClients) {
      final share = widget.scrollOffsetShare;
      if (share != null) {
        share.value = _scrollController.offset;
      }
    }
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
    // 时间轴起始小时动态化——显示范围内最早 timed 任务决定
    //（默认 6；06:00 前任务存在时扩展起始点，任务不再隐形不可操作）
    final startEff = _effectiveStartHour(days);
    final totalHours = endHour - startEff;

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
                          // 合并为一次 load（此前 setSelectedDay+setView 两次）
                          ? () => notifier.setSelectedDayWithView(d, 'day')
                          // 日视图头部可点击跳转其他日期（此前点击无反应）
                          : () async {
                              final now = AppClock.now();
                              // 日视图可翻至 2000-01-01，当前显示日超界
                              // 会触发 DatePicker 断言崩溃，钳制到 [first, last]；
                              // 下限 2000-01-01（页号基准，早于此日期得负页号
                              // 会被 PageController 静默钳制到基准日）
                              final first =
                                  DateTime(2000, 1, 1).isAfter(
                                        DateTime(now.year - 60),
                                      )
                                      ? DateTime(2000, 1, 1)
                                      : DateTime(now.year - 60);
                              final last = DateTime(now.year + 60);
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
            // 5.8/时间轴可见范围说明（动态起始小时，06:00 前有任务时
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
                    AllDayBar(
                      days: days,
                      byDay: widget.byDay,
                      axisWidth: axisWidth,
                    ),
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
                            padding: const EdgeInsets.symmetric(
                              vertical: axisTopPadding,
                            ),
                            itemCount: totalHours + 1,
                            itemBuilder: (context, i) {
                              final hour = startEff + i;
                              return SizedBox(
                                height: pixelPerHour,
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
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
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
                            padding: const EdgeInsets.symmetric(
                              vertical: axisTopPadding,
                            ),
                            children: [
                              // 时间轴主体（18 行，6:00~23:00 线）
                              SizedBox(
                                key: _axisKey,
                                height: totalHours * pixelPerHour,
                                child: Stack(
                                  children: [
                                    // 时间网格线（暗色适配）
                                    for (var h = 0; h <= totalHours; h++)
                                      Positioned(
                                        top: h * pixelPerHour - 0.5,
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 与 DayColumnState.columnWidth 同口径
                                        // （扣除时间栏 44px 后均分）
                                        for (
                                          var i = 0;
                                          i < days.length;
                                          i++
                                        ) ...[
                                          Expanded(
                                            child: DayColumn(
                                              day: days[i],
                                              items: _timedItems(days[i]),
                                              isWeek: widget.isWeek,
                                              startHour: startEff,
                                              axisWidth: axisWidth,
                                              dragDay: widget.dragDay,
                                              edgeState: widget.edgeState,
                                              scrollController:
                                                  _scrollController,
                                              onEdgeTurn: widget.onEdgeTurn,
                                              dragGlobalPos:
                                                  widget.dragGlobalPos,
                                              dragTaskId: widget.dragTaskId,
                                              dragActiveDay:
                                                  widget.dragActiveDay,
                                              dragGhostInfo:
                                                  widget.dragGhostInfo,
                                              dragDropped: widget.dragDropped,
                                              dragViewportTopY:
                                                  widget.dragViewportTopY,
                                              scrollOffsetShare:
                                                  widget.scrollOffsetShare,
                                              edgeTurnCtrl: widget.edgeTurnCtrl,
                                              onDragStartTracking:
                                                  widget.onDragStartTracking,
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
                                    NowLine(
                                      todayIndex: days.indexWhere(
                                        (d) => DateUtilsEx.sameDay(d, today),
                                      ),
                                      columnWidth:
                                          (axisWidth - 44) / days.length,
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
  bool _isTopArea(CalendarItem i) => AllDayBar.isTopArea(i);

  /// 显示范围内（当周/当天）timed 任务的最早开始小时，
  /// 与默认 6 取小——只扩展不收缩（多数情况保持 06:00 起点）。
  int _effectiveStartHour(List<DateTime> days) =>
      effectiveStartHourFor(byDay: widget.byDay, days: days);

  List<CalendarItem> _allDayItems(DateTime day) =>
      (widget.byDay[dayKey(day)] ?? const <CalendarItem>[])
          .where(_isTopArea)
          .toList();

  List<CalendarItem> _timedItems(DateTime day) =>
      (widget.byDay[dayKey(day)] ?? const <CalendarItem>[])
          .where((i) => !_isTopArea(i))
          .toList();
}

/// A7/A8：当前时间红线独立组件。
/// 自身 Timer 每秒检查分钟变化，跨分钟时用 55s 线性动画平滑移动
/// （走秒效果），只重绘自身——不再触发整个时间轴每分钟重建。


class NowLine extends StatefulWidget {
  const NowLine({
    super.key,
    required this.todayIndex,
    required this.columnWidth,
    required this.startHour,
  });

  /// 今天列索引（-1 = 不在今天，不显示）
  final int todayIndex;
  final double columnWidth;

  /// 时间轴起始小时（与 TimeAxisView 动态起始一致，红线随之下移）
  final int startHour;

  @override
  State<NowLine> createState() => NowLineState();
}

class NowLineState extends State<NowLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _prevTop = 0;
  double _nextTop = 0;
  Timer? _ticker;

  double _topFor(DateTime t) {
    final minutes = t.hour * 60 + t.minute;
    return (minutes - widget.startHour * 60) / 60 * pixelPerHour;
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
        if (delta > pixelPerHour) {
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
        if (top < 0 || top > (endHour - widget.startHour) * pixelPerHour) {
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


class AllDayBar extends ConsumerWidget {
  const AllDayBar({
    super.key,
    required this.days,
    required this.byDay,
    required this.axisWidth,
  });

  final List<DateTime> days;

  /// 按天分组索引（不再全窗口扫描）
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
      (byDay[dayKey(day)] ?? const <CalendarItem>[]).where(isTopArea).toList();

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
                          child: TaskBlock(
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

/// 边缘翻页控制器（WeekView/DayView 持有，跨页共享）：
/// 连续翻周链的 Timer/方向/最后位置不随列重建丢失，
/// 离开边缘/松手时任意列都可统一取消
