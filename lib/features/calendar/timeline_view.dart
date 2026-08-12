import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/task_ext.dart';
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
  const AxisKeepAlive({super.key, required this.child});

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
    // 尽力同步恢复（active 变化时 controller 可能已 attach）；post-frame
    // 兜底（_scheduleRestore）处理布局未完成的帧
    _restoreSharedScroll();
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
      // 页面尚未 attach：放宽重试上限（连续快速翻页 + 数据重建时布局
      // 延迟），耗尽后仍尽力上报基准，避免拖拽中基准长期陈旧
      if (_restoreAttempts++ < 12) {
        _scheduleRestore();
      } else {
        _reportAxisTopY();
      }
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    if (max == 0 && _restoreAttempts++ < 12) {
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
    // 缩放级别变化 → 重建（时间轴高/刻度/网格线/红线随 pp 刷新）
    final pp = ref.watch(pixelPerHourProvider);
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
                                  DateTime(
                                    2000,
                                    1,
                                    1,
                                  ).isAfter(DateTime(now.year - 60))
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
                  // 全天区固定在顶部（不随滚动，保证左右时间栏与网格线严格对齐）。
                  // 常驻组件树：空页在"置顶任务拖动中"也渲染最小高度落点条，
                  // 否则翻到无全天/跨天任务的周/日时无落点目标、拖动失效
                  AllDayBar(
                    days: days,
                    byDay: widget.byDay,
                    axisWidth: axisWidth,
                    dragGlobalPos: widget.dragGlobalPos,
                    dragTaskId: widget.dragTaskId,
                    dragActiveDay: widget.dragActiveDay,
                    dragGhostInfo: widget.dragGhostInfo,
                    dragDropped: widget.dragDropped,
                    onDragStartTracking: widget.onDragStartTracking,
                  ),
                  // 双指缩放时间轴（仅 2 指生效；单指滑动仍由 PageView/ListView 处理）
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 缩放最小值：整屏显示全部时段（含轴上下各半行留白），
                        // 缩到最小时 6-23 点全部可见、零滚动
                        final minPp =
                            (constraints.maxHeight - axisTopPadding * 2) /
                            totalHours;
                        return RawGestureDetector(
                          gestures: <Type, GestureRecognizerFactory>{
                            _ImmediateScaleRecognizer:
                                GestureRecognizerFactoryWithHandlers<
                                  _ImmediateScaleRecognizer
                                >(() => _ImmediateScaleRecognizer(), (r) {
                                  r.onStart = _scaleStart;
                                  r.onUpdate = (d) => _scaleUpdate(d, minPp);
                                  r.onEnd = (_) => _scaleEnd();
                                }),
                          },
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
                                      height: pp,
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
                                    // 时间轴主体（6:00~23:00 线）
                                    SizedBox(
                                      key: _axisKey,
                                      height: totalHours * pp,
                                      child: Stack(
                                        children: [
                                          // 时间网格线（暗色适配）
                                          for (var h = 0; h <= totalHours; h++)
                                            Positioned(
                                              top: h * pp - 0.5,
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
                                                    onEdgeTurn:
                                                        widget.onEdgeTurn,
                                                    dragGlobalPos:
                                                        widget.dragGlobalPos,
                                                    dragTaskId:
                                                        widget.dragTaskId,
                                                    dragActiveDay:
                                                        widget.dragActiveDay,
                                                    dragGhostInfo:
                                                        widget.dragGhostInfo,
                                                    dragDropped:
                                                        widget.dragDropped,
                                                    dragViewportTopY:
                                                        widget.dragViewportTopY,
                                                    scrollOffsetShare: widget
                                                        .scrollOffsetShare,
                                                    edgeTurnCtrl:
                                                        widget.edgeTurnCtrl,
                                                    onDragStartTracking: widget
                                                        .onDragStartTracking,
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
                                              (d) =>
                                                  DateUtilsEx.sameDay(d, today),
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
                        );
                      },
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

  // ---------- 双指缩放（仅 2 指生效；单指滑动由 PageView/ListView 处理） ----------
  /// 手势开始时（onScaleStart）的缩放级别——d.scale 的乘数基准
  double? _scaleStartPp;

  /// 上一帧的缩放级别（增量锚点基准，避免累计误差）
  double? _lastScalePp;

  /// 上一帧锚定后的垂直滚动位置（增量锚点基准）
  double _lastScaleScroll = 0;

  void _scaleStart(ScaleStartDetails d) {
    _scaleStartPp = ref.read(pixelPerHourProvider);
    _lastScalePp = _scaleStartPp;
    _lastScaleScroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0;
  }

  void _scaleUpdate(ScaleUpdateDetails d, double minPp) {
    if (d.pointerCount < 2) return;
    final startPp = _scaleStartPp;
    if (startPp == null) return;
    final newPp = (startPp * d.scale).clamp(minPp, maxPixelPerHour);
    final lastPp = _lastScalePp ?? startPp;
    // 增量锚定：以上一帧为基准，用当前两指中心（每帧实时）换算，内容不漂移。
    // 内容坐标（相对轴顶 offset=0）= focal 局部 y + scrollOffset - 轴顶 padding；
    // 缩放后按比例映射回新滚动位置（scroll 变化由 _onScroll 同步共享值）。
    // 不依赖 onScaleStart 时的 focal——onStart 可能在单指阶段触发
    //（focal = 第一指位置），每帧用实时双指中心即自动校正。
    final focal = d.localFocalPoint;
    final oldContentY = _lastScaleScroll + focal.dy - axisTopPadding;
    final newContentY = oldContentY * newPp / lastPp;
    _lastScalePp = newPp;
    if (_scrollController.hasClients) {
      final max = _scrollController.position.maxScrollExtent;
      final target = (newContentY + axisTopPadding - focal.dy).clamp(0.0, max);
      _lastScaleScroll = target;
      if ((_scrollController.offset - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
    }
    final notifier = ref.read(pixelPerHourProvider.notifier);
    if (notifier.state != newPp) {
      notifier.state = newPp;
    }
  }

  void _scaleEnd() {
    _scaleStartPp = null;
    _lastScalePp = null;
  }

  /// 是否显示在顶部置顶区（全天 / 无计划时间 / 跨天任务）
  bool _isTopArea(CalendarItem i) => AllDayBar.isTopArea(i);

  /// 显示范围内（当周/当天）timed 任务的最早开始小时，
  /// 与默认 6 取小——只扩展不收缩（多数情况保持 06:00 起点）。
  int _effectiveStartHour(List<DateTime> days) =>
      effectiveStartHourFor(byDay: widget.byDay, days: days);

  List<CalendarItem> _timedItems(DateTime day) =>
      (widget.byDay[dayKey(day)] ?? const <CalendarItem>[])
          .where((i) => !_isTopArea(i))
          .toList();
}

/// A7/A8：当前时间红线独立组件。
/// 自身 Timer 每秒检查分钟变化，跨分钟时用 55s 线性动画平滑移动
/// （走秒效果），只重绘自身——不再触发整个时间轴每分钟重建。

class NowLine extends ConsumerStatefulWidget {
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
  ConsumerState<NowLine> createState() => NowLineState();
}

class NowLineState extends ConsumerState<NowLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _prevTop = 0;
  double _nextTop = 0;
  Timer? _ticker;

  /// 上次 build 时的缩放级别（缩放变化时重置走秒动画起止点）
  double _lastPp = 0;

  double _topFor(DateTime t) {
    final minutes = t.hour * 60 + t.minute;
    return (minutes - widget.startHour * 60) /
        60 *
        ref.read(pixelPerHourProvider);
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
        if (delta > ref.read(pixelPerHourProvider)) {
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
    // 缩放级别变化 → 重建并重置走秒动画起止点（否则红线从旧缩放位置起跳）
    final pp = ref.watch(pixelPerHourProvider);
    if (pp != _lastPp) {
      _lastPp = pp;
      final now = AppClock.now();
      _prevTop = _nextTop = _topFor(now);
    }
    if (widget.todayIndex < 0) return const SizedBox.shrink();
    final lineColor = Theme.of(context).colorScheme.error;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final top = _prevTop + (_nextTop - _prevTop) * _controller.value;
        if (top < 0 || top > (endHour - widget.startHour) * pp) {
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

class AllDayBar extends ConsumerStatefulWidget {
  const AllDayBar({
    super.key,
    required this.days,
    required this.byDay,
    required this.axisWidth,
    this.dragGlobalPos,
    this.dragTaskId,
    this.dragActiveDay,
    this.dragGhostInfo,
    this.dragDropped,
    this.onDragStartTracking,
  });

  final List<DateTime> days;

  /// 按天分组索引（不再全窗口扫描）
  final Map<int, List<CalendarItem>> byDay;

  /// 内容区实际可用宽度（含左侧时间栏 44px；布局收窄后 ≠ 屏宽）
  final double axisWidth;

  /// 共享拖拽状态（全天任务长按拖动：置顶区横向改日 + 时间轴竖向转定时）
  final ValueNotifier<Offset?>? dragGlobalPos;
  final ValueNotifier<int?>? dragTaskId;
  final ValueNotifier<DateTime?>? dragActiveDay;
  final ValueNotifier<DragGhostInfo?>? dragGhostInfo;

  /// 正常落点已处理标志（置顶区落点后全局 route 的 up 兜底据此跳过）
  final ValueNotifier<bool>? dragDropped;

  /// 拖动开始上报指针（WeekView/DayView 注册全局 route 用）
  final void Function(int taskId, int pointer)? onDragStartTracking;

  /// 是否显示在顶部置顶区（全天 / 无计划时间 / 跨天任务）
  static bool isTopArea(CalendarItem i) {
    final t = i.task;
    if (t.isAllDay || t.planStart == null) return true;
    final ps = t.planStart!;
    final pe = t.planEnd ?? ps.add(const Duration(hours: 1));
    // 跨天：结束日期 ≠ 开始日期
    return !DateUtilsEx.sameDay(ps, pe);
  }

  @override
  ConsumerState<AllDayBar> createState() => AllDayBarState();
}

class AllDayBarState extends ConsumerState<AllDayBar> {
  /// 置顶区内容 GlobalKey：换算拖拽落点所在的列日（跨页稳定，不依赖
  /// 各页自身布局瞬态）
  final GlobalKey _contentKey = GlobalKey();

  static final ValueNotifier<Offset?> _noopPos = ValueNotifier<Offset?>(null);

  static final ValueNotifier<DragGhostInfo?> _noopGhost =
      ValueNotifier<DragGhostInfo?>(null);

  /// 空目标页（无置顶任务）拖动中的落点条最小高度——保证 DragTarget
  /// 有可命中的尺寸（高度 0 无法接收拖放）
  static const double _dropStripHeight = 32;

  /// 按下指针 id（onPointerDown 捕获 → 拖动开始时注册全局 route）
  int? _pointer;

  List<CalendarItem> _allDayItems(DateTime day) =>
      (widget.byDay[dayKey(day)] ?? const <CalendarItem>[])
          .where(AllDayBar.isTopArea)
          .toList();

  Task? _taskById(int id) {
    for (final it in ref.read(calendarControllerProvider).items) {
      if (it.task.id == id) return it.task;
    }
    return null;
  }

  /// 任务查询（跨页拖拽用）：当前视图 items 只含当前范围，翻页后被拖
  /// 任务不在其中——items 命中优先，未命中回退 DB 权威查询
  Future<Task?> _taskByIdAsync(int id) async {
    final inMemory = _taskById(id);
    if (inMemory != null) return inMemory;
    final db = ref.read(dbProvider);
    try {
      return await db.getTask(id);
    } catch (_) {
      return null;
    }
  }

  /// 是否跨天定时任务（起止不同日，出现在置顶区，拖动整体平移天数）
  bool _taskIsCrossDay(Task t) {
    final ps = t.planStart;
    final pe = t.planEnd;
    if (ps == null || pe == null) return false;
    return !DateUtilsEx.sameDay(ps, pe);
  }

  /// 拖动指针全局 x → 置顶区列索引（被拖任务为全天/跨天时才显示高亮）。
  /// 翻页动画中本列局部→全局换算可能为 NaN（页面滑动瞬态），跳过高亮
  int? _colFor(Offset? gpos) {
    if (gpos == null) return null;
    final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final left = box.localToGlobal(Offset.zero).dx;
    if (!left.isFinite || !gpos.dx.isFinite) return null;
    final columnWidth = (widget.axisWidth - 44) / widget.days.length;
    return ((gpos.dx - left) / columnWidth).floor().clamp(
      0,
      widget.days.length - 1,
    );
  }

  /// 统一清理共享拖拽状态（落点/松手：虚影/胶囊/高亮消失）
  void _clearDragState() {
    widget.dragTaskId?.value = null;
    widget.dragGlobalPos?.value = null;
    widget.dragActiveDay?.value = null;
    widget.dragGhostInfo?.value = null;
  }

  /// 置顶区落点：
  /// - 全天任务：改期到落点所在日（保持全天）；
  /// - 跨天定时任务：整体平移 N 天到落点日（落点日 = 新开始日，
  ///   保留原起止时分与时长）；
  /// 重复任务弹"更改整个系列？"确认后平移系列（可撤销）
  Future<void> _dropOnBar(int taskId) async {
    // 与 DayColumn 一致：先置位"已处理"标志——全局 route 的 up 兜底据此跳过
    widget.dragDropped?.value = true;
    final gpos = widget.dragGlobalPos?.value;
    final col = _colFor(gpos);
    final t = await _taskByIdAsync(taskId);
    if (!mounted) return;
    if (gpos == null || col == null || t == null) {
      _clearDragState();
      return;
    }
    final day = widget.days[col];
    final crossDay = !t.isAllDay && _taskIsCrossDay(t);
    final notifier = ref.read(calendarControllerProvider.notifier);
    if (t.rrule.isNotEmpty) {
      final content = crossDay
          ? '「${t.title}」是重复任务。\n'
                '将把整个系列整体平移（保持起止时间与时长）到 '
                '${DateUtilsEx.dateCn(day)} 开始，旧日期上的完成记录将被清理。\n\n'
                '只想改这一天，请用「跳过本次 / 改期」菜单。'
          : '「${t.title}」是重复任务。\n'
                '将把整个系列改为从 ${DateUtilsEx.dateCn(day)} 开始'
                '（保持全天），旧日期上的完成记录将被清理。\n\n'
                '只想改这一天，请用「跳过本次 / 改期」菜单。';
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('更改整个系列？'),
          content: Text(content),
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
        _clearDragState();
        return;
      }
      if (crossDay) {
        await notifier.moveCrossDaySeriesToDate(taskId, day);
      } else {
        await notifier.moveAllDaySeriesToDate(taskId, day);
      }
      _clearDragState();
      if (mounted) {
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
    if (crossDay) {
      await notifier.moveCrossDayToDate(taskId, day);
    } else {
      await notifier.moveAllDayToDate(taskId, day);
    }
    _clearDragState();
  }

  @override
  Widget build(BuildContext context) {
    // 与下方时间轴内容区同宽同起点（左侧 44px 时间栏占位），保证列严格对齐
    final contentWidth = widget.axisWidth - 44;
    final columnWidth = contentWidth / widget.days.length;
    final scheme = Theme.of(context).colorScheme;
    final hasItems = widget.days.any((d) => _allDayItems(d).isNotEmpty);
    return ValueListenableBuilder<DragGhostInfo?>(
      valueListenable: widget.dragGhostInfo ?? _noopGhost,
      builder: (context, ghost, _) {
        // 置顶区任务（全天/跨天）拖动中：即使本页无置顶任务也渲染落点条——
        // 否则翻到无任务的周/日时全天拖动没有可命中的 DragTarget
        final draggingTopArea = ghost?.isTopArea == true;
        if (!hasItems && !draggingTopArea) return const SizedBox.shrink();
        return Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 44),
                SizedBox(
                  key: _contentKey,
                  width: contentWidth,
                  child: DragTarget<int>(
                    // 仅全天/跨天定时任务可落在置顶区
                    onWillAcceptWithDetails: (d) {
                      // 拖动开始瞬间 onWillAccept 先于 onDragStartedTask 触发
                      //（此时 dragGhostInfo 尚未写入）——优先按当前视图 items
                      // 查类型；跨页翻走后 items 不含被拖任务，再用拖动开始
                      // 时报的 dragGhostInfo 兜底
                      final t = _taskById(d.data);
                      if (t != null) {
                        return t.isAllDay || _taskIsCrossDay(t);
                      }
                      return widget.dragGhostInfo?.value?.isTopArea == true;
                    },
                    onAcceptWithDetails: (d) => _dropOnBar(d.data),
                    builder: (context, _, _) {
                      return ValueListenableBuilder<Offset?>(
                        valueListenable: widget.dragGlobalPos ?? _noopPos,
                        builder: (context, gpos, _) {
                          final hl = draggingTopArea ? _colFor(gpos) : null;
                          // 空目标页拖动中：给落点条最小高度，保证可命中
                          return Container(
                            constraints: BoxConstraints(
                              minHeight: draggingTopArea && !hasItems
                                  ? _dropStripHeight
                                  : 0,
                            ),
                            child: Stack(
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (var i = 0; i < widget.days.length; i++)
                                      SizedBox(
                                        width: columnWidth,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            for (final item in _allDayItems(
                                              widget.days[i],
                                            ))
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 2,
                                                ),
                                                // C5-1/C3-4：仅真正的全天
                                                // 任务 allDay=true；跨天定时
                                                // 任务显示起止时刻（拖动仅
                                                // 置顶区改日整体平移）
                                                child: TaskBlock(
                                                  item: item,
                                                  allDay: item.task.isAllDay,
                                                  showTime: !item.task.isAllDay,
                                                  // 按下指针上报（注册全局
                                                  // route 用）
                                                  onPointerDown: (p) =>
                                                      _pointer = p,
                                                  onDragStartedTask: (id) {
                                                    widget.dragTaskId?.value =
                                                        id;
                                                    // 虚影信息：置顶区任务
                                                    // 拖进时间轴无效，只标记
                                                    // 类型供虚影隐藏
                                                    final it = _taskById(id);
                                                    if (it != null) {
                                                      widget
                                                              .dragGhostInfo
                                                              ?.value =
                                                          DragGhostInfo(
                                                            title: it.title,
                                                            durationMinutes: it
                                                                .durationMinutes,
                                                            color: it.color,
                                                            listColor:
                                                                item.listColor,
                                                            isAllDay:
                                                                it.isAllDay,
                                                            isCrossDay:
                                                                _taskIsCrossDay(
                                                                  it,
                                                                ),
                                                          );
                                                    }
                                                    final p = _pointer;
                                                    if (p != null) {
                                                      widget.onDragStartTracking
                                                          ?.call(id, p);
                                                    }
                                                  },
                                                  onDragPosition: (g) =>
                                                      widget
                                                              .dragGlobalPos
                                                              ?.value =
                                                          g,
                                                  onDragEnd: () =>
                                                      _clearDragState(),
                                                  // 拖拽取消/列 evict：共享
                                                  // 状态由全局 route 统一清理
                                                  onDragCanceled: () {},
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                                // 置顶区任务（全天/跨天）拖动中：高亮目标
                                // 日槽位（横向改日/整体平移提示）
                                if (hl != null)
                                  Positioned(
                                    left: hl * columnWidth,
                                    width: columnWidth,
                                    top: 0,
                                    bottom: 0,
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: scheme.primary.withValues(
                                            alpha: 0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: scheme.primary,
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            if (hasItems || draggingTopArea)
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
          ],
        );
      },
    );
  }
}

/// 边缘翻页控制器（WeekView/DayView 持有，跨页共享）：
/// 连续翻周链的 Timer/方向/最后位置不随列重建丢失，
/// 离开边缘/松手时任意列都可统一取消

/// 时间轴缩放识别器：双指一到位立即赢得手势竞技场。
/// 默认 ScaleGestureRecognizer 需等两指移动超过 slop 才 accepted——若第一指
/// 先落地且微动超过 ListView/PageView 的 drag slop，drag 已抢先 started，
/// scale 被判负、onScaleStart 不再触发，双指捏合完全无反应。
/// 覆写 addAllowedPointer/handleEvent：第二指 down 或 move 时 pointerCount>=2
/// 立即 resolve(accepted)，抢在 drag 之前占位；单指时保持默认让位（不破坏
/// 单指滚动/翻页）。
class _ImmediateScaleRecognizer extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }
}
