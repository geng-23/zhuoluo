import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/features/calendar/calendar_axis.dart';
import 'package:zhuoluo/features/calendar/day_column.dart';
import 'package:zhuoluo/features/calendar/timeline_view.dart';

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

  /// 按天分组索引（视图 build 不再全窗口扫描）
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
  final ValueNotifier<int> _activePage = ValueNotifier<int>(500);

  /// 拖动/选时跨页时的目标日期（随翻页更新；初始=当前显示周的周一）
  final ValueNotifier<DateTime> _dragDay = ValueNotifier<DateTime>(
    AppClock.now(),
  );

  /// 共享边缘滞回状态（贯穿所有页，不随翻页重建丢失）：
  /// 0=未触发，1=向右已翻，-1=向左已翻；手指回中间才允许再次触发
  final ValueNotifier<int> _edgeState = ValueNotifier<int>(0);

  // ---------- 共享拖拽状态（拖动任务改期跨页保持） ----------
  /// 拖动中最后已知的全局指针位置（虚影/胶囊渲染坐标换算用）
  final ValueNotifier<Offset?> dragGlobalPos = ValueNotifier<Offset?>(null);

  /// 拖动中的任务 id（null = 无拖动）
  final ValueNotifier<int?> dragTaskId = ValueNotifier<int?>(null);

  /// 虚影/胶囊显示列（边缘翻页后由 _edgeTurn 更新为新页边缘列）
  final ValueNotifier<DateTime?> dragActiveDay = ValueNotifier<DateTime?>(null);

  /// 拖动任务显示信息（跨周后视图 items 不含旧周任务，虚影据此渲染）
  final ValueNotifier<DragGhostInfo?> dragGhostInfo =
      ValueNotifier<DragGhostInfo?>(null);

  /// 共享边缘翻页控制器（连续翻周链跨页保持）
  final EdgeTurnController _edgeTurnCtrl = EdgeTurnController();

  /// 正常落点已处理标志（onAcceptWithDetails 设置——全局 route 的 up
  /// 兜底据此跳过，避免重复改期）
  final ValueNotifier<bool> dragDropped = ValueNotifier<bool>(false);

  // ---------- 全局指针事件驱动（跨页拖动：Draggable 被 evict 后仍可靠） ----------
  /// 拖动中注册到 pointerRouter 的指针（up/取消时移除）
  int? _dragPointer;

  /// 拖动任务 id 副本（松手/取消会清共享状态——落点兜底用）
  int? _dragTaskId;

  /// 拖动任务信息副本（同原因，落点兜底用）
  DragGhostInfo? _dragInfo;

  /// 落点 y 换算基准：当前页时间轴主体顶部全局 y（各页 post-frame
  /// 上报 + 滚动修正，当前可见页最后写入）
  final ValueNotifier<double> dragAxisTopY = ValueNotifier<double>(0);

  /// 当前页时间轴 scrollController（各页 post-frame 上报——翻页后
  /// Draggable 被 evict 时全局 route 据此接管垂直自动滚动）
  final ValueNotifier<ScrollController?> dragScrollCtrl =
      ValueNotifier<ScrollController?>(null);

  /// 当前页时间轴视口顶部全局 y + 视口高（垂直自动滚动触发区换算用）
  final ValueNotifier<double> dragViewportTopY = ValueNotifier<double>(0);
  final ValueNotifier<double> dragViewportH = ValueNotifier<double>(0);

  /// 全局垂直自动滚动 Timer（16ms 步进 jumpTo ±8px；松手/取消停止）
  Timer? _autoScrollTimer;

  /// 共享垂直滚动位置（跨周翻页时新周继承当前滚动位置，避免跳回顶部）
  /// 优先使用外部传入的共享 notifier（周↔日切换连续）
  late final ValueNotifier<double> _sharedScrollOffset;
  ValueNotifier<double>? _ownScroll;

  /// 外部跳页目标页。跳页触发的 onPageChanged 只同步 _dragDay、
  /// 不回写 selectedDay（否则点"今天"后选中日被回归为周一）。
  int? _pendingExternalPage;

  /// 固定周基准（initState 时刻的当前周周一），state 生命周期内
  /// 不再变化，与 DayView 固定日基准（2000-01-01）同一模式。此前以
  /// mondayOf(widget.selectedDay) 为基准，而 didUpdateWidget 中
  /// widget.selectedDay 已是新值 → 差恒为 0 → 目标页恒为 500：
  /// 手动翻周必触发 280ms 弹回动画、跨周外部跳转恒落回 App 打开时
  /// 那一周（上版误判 已修复，本轮翻案）。
  late final DateTime _epochMonday;

  int _pageForMonday(DateTime monday) =>
      500 + monday.difference(_epochMonday).inDays ~/ 7;

  @override
  void initState() {
    super.initState();
    _epochMonday = DateUtilsEx.mondayOf(AppClock.now());
    _activePage.value = _pageForMonday(
      DateUtilsEx.mondayOf(widget.selectedDay),
    );
    _sharedScrollOffset =
        widget.sharedScrollOffset ?? (_ownScroll = ValueNotifier<double>(0));
    _dragDay.value = DateUtilsEx.mondayOf(widget.selectedDay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.hasClients) {
        final target = _pageForMonday(DateUtilsEx.mondayOf(widget.selectedDay));
        // 初始定位：jumpToPage 瞬跳（不产生 ScrollUpdateNotification，
        // 不触发 onPageChanged）——无需动画拦截；下一帧兜底清除 pending
        //（否则残留会误拦后续翻页的 onPageChanged 回写）
        _pendingExternalPage = target;
        _controller.jumpToPage(target);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pendingExternalPage = null;
        });
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
      _controller
          .animateToPage(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            // 动画结束（含被手势打断）→ 结束拦截，防 pending 残留
            if (mounted) _pendingExternalPage = null;
          });
      _dragDay.value = newMonday;
    }
  }

  @override
  void dispose() {
    _unregisterDragRoute();
    _controller.dispose();
    _activePage.dispose();
    _dragDay.dispose();
    _edgeState.dispose();
    dragGlobalPos.dispose();
    dragTaskId.dispose();
    dragActiveDay.dispose();
    dragGhostInfo.dispose();
    dragDropped.dispose();
    dragAxisTopY.dispose();
    dragScrollCtrl.dispose();
    dragViewportTopY.dispose();
    dragViewportH.dispose();
    _stopAutoScroll();
    _edgeTurnCtrl.timer?.cancel();
    // 仅释放自建的滚动 notifier（外部传入的由持有者管理）
    _ownScroll?.dispose();
    super.dispose();
  }

  /// 边缘翻页（连续翻周：节奏由 _armEdgeTimer/_armContinuation 的
  /// 300ms/800ms Timer 链控制，无需额外节流）
  void _edgeTurn(double dx) {
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
    // 同步目标日 + 虚影跟随到新页边缘列（右缘 → 新页最后一列，左缘 → 新页第一列）
    final offset = page - 500 + (dx > 0 ? 1 : -1);
    final targetMonday = _epochMonday.add(Duration(days: offset * 7));
    _dragDay.value = targetMonday;
    dragActiveDay.value = dx > 0
        ? targetMonday.add(const Duration(days: 6))
        : targetMonday;
  }

  // ---------- 全局指针事件驱动（跨页拖动） ----------

  /// 拖动开始：注册 pointerRouter route（Draggable 跨页被 evict/dispose 后
  /// onDragUpdate 静默失效——本 route 独立于 Draggable State，全程可靠）
  void _registerDragRoute(int taskId, int pointer) {
    _unregisterDragRoute();
    _dragPointer = pointer;
    _dragTaskId = taskId;
    _dragInfo = dragGhostInfo.value;
    GestureBinding.instance.pointerRouter.addRoute(
      pointer,
      _onDragPointerEvent,
    );
  }

  void _unregisterDragRoute() {
    final p = _dragPointer;
    if (p != null) {
      GestureBinding.instance.pointerRouter.removeRoute(p, _onDragPointerEvent);
      _dragPointer = null;
    }
  }

  void _onDragPointerEvent(PointerEvent e) {
    if (e is PointerMoveEvent) {
      // 共享拖拽位置（虚影/胶囊跟随）+ 边缘翻页检测（反向/连续均可靠）
      // + 垂直自动滚动（翻页后 Draggable evict 仍可靠）
      dragGlobalPos.value = e.position;
      _maybeEdgeTurn(e.position.dx);
      _checkVerticalAutoScrollGlobal(e.position.dy);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _unregisterDragRoute();
      if (e is PointerUpEvent) {
        _handleDragDrop(e.position);
      } else {
        _clearDragSharedState();
      }
    }
  }

  /// 统一清理共享拖拽状态（松手/取消：虚影/胶囊 + 连续翻页链）
  void _clearDragSharedState() {
    dragTaskId.value = null;
    dragGlobalPos.value = null;
    dragActiveDay.value = null;
    dragGhostInfo.value = null;
    dragDropped.value = false;
    _dragTaskId = null;
    _dragInfo = null;
    _edgeTurnCtrl.timer?.cancel();
    _edgeTurnCtrl.timer = null;
    _edgeTurnCtrl.dir = 0;
    _edgeTurnCtrl.armed = false;
    _stopAutoScroll();
  }

  /// 垂直自动滚动（全局 route 驱动）：手指接近时间轴视口顶部/底部
  /// 触发自动滚动。翻页后 Draggable 被 evict 时 onDragUpdate 失效
  ///（列版 _checkVerticalAutoScroll 停止工作）——本层用各页上报的
  /// 视口信息接管，翻页后上下边缘滚动依然可用。
  void _checkVerticalAutoScrollGlobal(double globalDy) {
    final scroll = dragScrollCtrl.value;
    if (scroll == null || !scroll.hasClients) return;
    final viewportTop = dragViewportTopY.value;
    final viewportH = dragViewportH.value;
    final fingerY = globalDy - viewportTop;
    // 上滑触发区 30px；下滑触发区 90px（与列版一致，底部靠近导航栏放宽）
    if (fingerY < 30) {
      _startAutoScroll(scroll, -1);
    } else if (fingerY > viewportH - 90) {
      _startAutoScroll(scroll, 1);
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll(ScrollController scroll, int dir) {
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!scroll.hasClients) {
        _stopAutoScroll();
        return;
      }
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

  /// 边缘翻周/日：进入边缘区停留 300ms 触发首次翻页；
  /// 翻页后若指针仍停边缘（保持区：右缘链 x>65%、左缘链 x<35%）→ 每
  /// 500ms 自动续翻（连续拖到多个周以后），触摸点微漂移不断链；
  /// 移出保持区（拖回中间定位）或松手即停止。
  /// （与 DayColumn 内同名方法逻辑一致，共享 edgeTurnCtrl——本层为
  /// 全局 route 驱动，列版为 Draggable onDragUpdate 驱动，双源幂等）
  void _maybeEdgeTurn(double globalX) {
    _edgeTurnCtrl.lastGlobalX = globalX;
    final w = MediaQuery.sizeOf(context).width;
    // 保持区滞回：链已启动时，右缘链 x>65%、左缘链 x<35% 持续翻页
    //（触摸点微漂移不出链）；移出保持区停链并继续按触发区判断（反向）
    if (_edgeTurnCtrl.armed) {
      final keep = _edgeTurnCtrl.dir > 0
          ? globalX > w * 0.65
          : globalX < w * 0.35;
      if (keep) return;
      _edgeTurnCtrl.timer?.cancel();
      _edgeTurnCtrl.timer = null;
      _edgeTurnCtrl.dir = 0;
      _edgeTurnCtrl.armed = false;
    }
    if (globalX > w * 0.85) {
      _armEdgeTimer(1, w);
    } else if (globalX < w * 0.06) {
      _armEdgeTimer(-1, w);
    } else {
      _edgeTurnCtrl.timer?.cancel();
      _edgeTurnCtrl.timer = null;
      _edgeTurnCtrl.dir = 0;
      _edgeTurnCtrl.armed = false;
    }
  }

  void _armEdgeTimer(int dir, double w) {
    if (_edgeTurnCtrl.timer != null && _edgeTurnCtrl.dir == dir) return;
    _edgeTurnCtrl.timer?.cancel();
    _edgeTurnCtrl.dir = dir;
    _edgeTurnCtrl.timer = Timer(const Duration(milliseconds: 300), () {
      _edgeTurnCtrl.timer = null;
      _edgeTurnCtrl.armed = true;
      _edgeTurn(dir.toDouble());
      _armContinuation(dir, w);
    });
  }

  void _armContinuation(int dir, double w) {
    // 保持区续链（按方向：右缘链看 x>65%、左缘链看 x<35%）
    final keep = dir > 0
        ? _edgeTurnCtrl.lastGlobalX > w * 0.65
        : _edgeTurnCtrl.lastGlobalX < w * 0.35;
    if (keep) {
      _edgeTurnCtrl.timer = Timer(const Duration(milliseconds: 500), () {
        _edgeTurnCtrl.timer = null;
        _edgeTurn(dir.toDouble());
        _armContinuation(dir, w);
      });
    }
  }

  /// 落点兜底：Draggable 被 evict 后（正常 onAcceptWithDetails 未触发），
  /// 松手时按 route 上下文副本（taskId/时长）+ 指针位置精确换算落点并
  /// 执行改期——任务不再回退。
  /// 不依赖共享 dragActiveDay/dragGhostInfo（松手/取消会清它们）
  Future<void> _handleDragDrop(Offset pos) async {
    if (dragDropped.value) {
      // 正常路径已处理
      dragDropped.value = false;
      _clearDragSharedState();
      return;
    }
    final taskId = _dragTaskId;
    final info = _dragInfo;
    if (taskId == null || info == null) {
      _clearDragSharedState();
      return;
    }
    // 落点日期：指针 x → 列索引（当前周基准 _dragDay 随翻页更新，
    // 不被松手/取消清理）——周视图 7 列
    final colWidth = (MediaQuery.sizeOf(context).width - 44) / 7;
    final col = ((pos.dx - 44) / colWidth).floor().clamp(0, 6);
    final day = _dragDay.value.add(Duration(days: col));
    // 时间轴主体顶部全局 y（各页 post-frame 上报，当前页最后写入）
    final localDy = pos.dy - dragAxisTopY.value;
    final startHour = effectiveStartHourFor(byDay: widget.byDay, days: [day]);
    final minutes = (startHour * 60 + localDy / pixelPerHour * 60)
        .roundToDouble()
        .clamp(startHour * 60.0, endHour * 60.0);
    final snapped = ((minutes / 10).round() * 10).clamp(
      startHour * 60,
      endHour * 60,
    );
    final target = AppClock.at(
      day.year,
      day.month,
      day.day,
      snapped ~/ 60,
      snapped % 60,
    );
    final start = DateUtilsEx.clampStartWithinDay(
      target,
      Duration(minutes: info.durationMinutes),
    );
    _clearDragSharedState();
    // 系列任务需确认（与 onAcceptWithDetails 行为一致）
    final db = ref.read(dbProvider);
    final task = await db.getTask(taskId);
    if (task == null) return;
    final notifier = ref.read(calendarControllerProvider.notifier);
    if (task.rrule.isNotEmpty) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('更改整个系列？'),
          content: Text(
            '「${task.title}」是重复任务。\n'
            '将把整个系列改为从 ${DateUtilsEx.timeCn(start)} 开始'
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
      if (ok == true) {
        await notifier.moveTaskToDateTimeSeries(taskId, start);
      }
    } else {
      await notifier.moveTaskToDateTime(taskId, start);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      // itemCount 随固定基准同步扩大（自 _epochMonday 起每周一页，
      // 与 DayView 的 40000 对称，前后各覆盖约 380 年）
      itemCount: 40000,
      // A13：allowImplicitScrolling 预构建页在 widget 测试 teardown 时
      // 触发 deactivate 时序问题（NowLine Timer pending），暂不启用；
      // 丝滑翻页主要靠窗口缓存（翻页零 DB）+ byDay 分组 build 减负
      onPageChanged: (page) {
        _activePage.value = page;
        final offset = page - 500;
        final weekMonday = _epochMonday.add(Duration(days: offset * 7));
        // 外部跳页（今天按钮/日期选择）动画期间——onPageChanged
        // 在动画中（round 变化）多次触发，一律只同步 _dragDay、不回写
        // selectedDay（否则回写→didUpdateWidget→animateToPage 回跳打断
        // 动画，最终停在中间页/月）；到达目标页时结束拦截
        if (_pendingExternalPage != null) {
          _dragDay.value = weekMonday;
          if (page == _pendingExternalPage) {
            _pendingExternalPage = null;
          }
          return;
        }
        // 手动翻页时同步 _dragDay（与 DayView 一致），
        // 修复翻周后长按选时创建到旧周的问题
        _dragDay.value = weekMonday;
        widget.onDayChanged(weekMonday);
      },
      itemBuilder: (context, page) {
        final offset = page - 500;
        final weekStart = _epochMonday.add(Duration(days: offset * 7));
        return AxisKeepAlive(
          child: TimeAxisView(
            pageIndex: page,
            activePage: _activePage,
            items: widget.items,
            byDay: widget.byDay,
            start: weekStart,
            isWeek: true,
            selectedDay: widget.selectedDay,
            dragDay: _dragDay,
            edgeState: _edgeState,
            scrollOffsetShare: _sharedScrollOffset,
            onEdgeTurn: _edgeTurn,
            dragGlobalPos: dragGlobalPos,
            dragTaskId: dragTaskId,
            dragActiveDay: dragActiveDay,
            dragGhostInfo: dragGhostInfo,
            dragDropped: dragDropped,
            dragAxisTopY: dragAxisTopY,
            dragScrollCtrl: dragScrollCtrl,
            dragViewportTopY: dragViewportTopY,
            dragViewportH: dragViewportH,
            edgeTurnCtrl: _edgeTurnCtrl,
            onDragStartTracking: (taskId, pointer) =>
                _registerDragRoute(taskId, pointer),
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

  /// 按天分组索引（视图 build 不再全窗口扫描）
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
  late final ValueNotifier<int> _activePage;
  final ValueNotifier<DateTime> _dragDay = ValueNotifier<DateTime>(
    AppClock.now(),
  );

  /// 共享边缘滞回状态（同 WeekView）
  final ValueNotifier<int> _edgeState = ValueNotifier<int>(0);

  // ---------- 共享拖拽状态（拖动任务改期跨页保持，同 WeekView） ----------
  final ValueNotifier<Offset?> dragGlobalPos = ValueNotifier<Offset?>(null);
  final ValueNotifier<int?> dragTaskId = ValueNotifier<int?>(null);
  final ValueNotifier<DateTime?> dragActiveDay = ValueNotifier<DateTime?>(null);

  /// 拖动任务显示信息（同 WeekView）
  final ValueNotifier<DragGhostInfo?> dragGhostInfo =
      ValueNotifier<DragGhostInfo?>(null);

  /// 共享边缘翻页控制器（连续翻日链跨页保持）
  final EdgeTurnController _edgeTurnCtrl = EdgeTurnController();

  /// 正常落点已处理标志（同 WeekView）
  final ValueNotifier<bool> dragDropped = ValueNotifier<bool>(false);

  /// 落点 y 换算基准：当前页时间轴主体顶部全局 y（各页 post-frame 上报）
  final ValueNotifier<double> dragAxisTopY = ValueNotifier<double>(0);

  /// 当前页时间轴 scrollController（各页 post-frame 上报——翻页后
  /// Draggable 被 evict 时全局 route 据此接管垂直自动滚动，同 WeekView）
  final ValueNotifier<ScrollController?> dragScrollCtrl =
      ValueNotifier<ScrollController?>(null);

  /// 当前页时间轴视口顶部全局 y + 视口高（垂直自动滚动触发区换算用）
  final ValueNotifier<double> dragViewportTopY = ValueNotifier<double>(0);
  final ValueNotifier<double> dragViewportH = ValueNotifier<double>(0);

  /// 全局垂直自动滚动 Timer（16ms 步进 jumpTo ±8px；松手/取消停止）
  Timer? _autoScrollTimer;

  /// 共享垂直滚动位置（跨日翻页时新日继承当前滚动位置）
  /// 优先使用外部传入的共享 notifier（周↔日切换连续）
  late final ValueNotifier<double> _sharedScrollOffset;
  ValueNotifier<double>? _ownScroll;

  int _pageFor(DateTime d) {
    // ：按应用时区日期字段计算页号（两侧同口径，跨时区不偏移）
    final a = AppClock.asApp(d);
    return AppClock.at(
      a.year,
      a.month,
      a.day,
    ).difference(AppClock.at(2000, 1, 1)).inDays;
  }

  @override
  void initState() {
    super.initState();
    _sharedScrollOffset =
        widget.sharedScrollOffset ?? (_ownScroll = ValueNotifier<double>(0));
    _controller = PageController(initialPage: _pageFor(widget.selectedDay));
    _activePage = ValueNotifier<int>(_pageFor(widget.selectedDay));
    _dragDay.value = widget.selectedDay;
  }

  @override
  void didUpdateWidget(DayView old) {
    super.didUpdateWidget(old);
    if (!DateUtilsEx.sameDay(old.selectedDay, widget.selectedDay) &&
        _controller.hasClients) {
      final target = _pageFor(widget.selectedDay);
      final current = _controller.page?.round() ?? target;
      // 手动翻页后 selectedDay 已同步（onPageChanged 回写）→ 当前页即
      // 目标页，跳过（否则每次翻页追加 280ms 多余动画，观感发涩）
      if (current == target) {
        _dragDay.value = widget.selectedDay;
        return;
      }
      // 外部跳日（今天按钮/DatePicker/头部）→ 平滑翻到对应页；动画期间
      // onPageChanged 拦截回写（防回跳打断停在中间日）
      _pendingExternalPage = target;
      _controller
          .animateToPage(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (mounted) _pendingExternalPage = null;
          });
      _dragDay.value = widget.selectedDay;
    }
  }

  @override
  void dispose() {
    _unregisterDragRoute();
    _controller.dispose();
    _activePage.dispose();
    _dragDay.dispose();
    _edgeState.dispose();
    dragGlobalPos.dispose();
    dragTaskId.dispose();
    dragActiveDay.dispose();
    dragGhostInfo.dispose();
    dragDropped.dispose();
    dragAxisTopY.dispose();
    dragScrollCtrl.dispose();
    dragViewportTopY.dispose();
    dragViewportH.dispose();
    _stopAutoScroll();
    _edgeTurnCtrl.timer?.cancel();
    // 仅释放自建的滚动 notifier（外部传入的由持有者管理）
    _ownScroll?.dispose();
    super.dispose();
  }

  void _edgeTurn(double dx) {
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
    _dragDay.value = AppClock.at(
      2000,
      1,
      1,
    ).add(Duration(days: page + (dx > 0 ? 1 : -1)));
    // 虚影跟随到新页（日视图单列即目标日）
    dragActiveDay.value = _dragDay.value;
  }

  // ---------- 全局指针事件驱动（跨页拖动，同 WeekView） ----------
  int? _dragPointer;

  /// 拖动任务 id 副本（松手/取消会清共享状态——落点兜底用）
  int? _dragTaskId;

  /// 拖动任务信息副本（同原因，落点兜底用）
  DragGhostInfo? _dragInfo;

  /// 外部跳日目标页（今天/DatePicker/头部）——动画期间 onPageChanged
  /// 拦截回写 selectedDay，防回跳打断动画停在中间日
  int? _pendingExternalPage;

  void _registerDragRoute(int taskId, int pointer) {
    _unregisterDragRoute();
    _dragPointer = pointer;
    _dragTaskId = taskId;
    _dragInfo = dragGhostInfo.value;
    GestureBinding.instance.pointerRouter.addRoute(
      pointer,
      _onDragPointerEvent,
    );
  }

  void _unregisterDragRoute() {
    final p = _dragPointer;
    if (p != null) {
      GestureBinding.instance.pointerRouter.removeRoute(p, _onDragPointerEvent);
      _dragPointer = null;
    }
  }

  void _onDragPointerEvent(PointerEvent e) {
    if (e is PointerMoveEvent) {
      dragGlobalPos.value = e.position;
      _maybeEdgeTurn(e.position.dx);
      _checkVerticalAutoScrollGlobal(e.position.dy);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _unregisterDragRoute();
      if (e is PointerUpEvent) {
        _handleDragDrop(e.position);
      } else {
        _clearDragSharedState();
      }
    }
  }

  void _clearDragSharedState() {
    dragTaskId.value = null;
    dragGlobalPos.value = null;
    dragActiveDay.value = null;
    dragGhostInfo.value = null;
    dragDropped.value = false;
    _dragTaskId = null;
    _dragInfo = null;
    _edgeTurnCtrl.timer?.cancel();
    _edgeTurnCtrl.timer = null;
    _edgeTurnCtrl.dir = 0;
    _edgeTurnCtrl.armed = false;
    _stopAutoScroll();
  }

  /// 垂直自动滚动（全局 route 驱动）：手指接近时间轴视口顶部/底部
  /// 触发自动滚动。翻页后 Draggable 被 evict 时 onDragUpdate 失效
  ///（列版 _checkVerticalAutoScroll 停止工作）——本层用各页上报的
  /// 视口信息接管，翻页后上下边缘滚动依然可用。
  void _checkVerticalAutoScrollGlobal(double globalDy) {
    final scroll = dragScrollCtrl.value;
    if (scroll == null || !scroll.hasClients) return;
    final viewportTop = dragViewportTopY.value;
    final viewportH = dragViewportH.value;
    final fingerY = globalDy - viewportTop;
    // 上滑触发区 30px；下滑触发区 90px（与列版一致，底部靠近导航栏放宽）
    if (fingerY < 30) {
      _startAutoScroll(scroll, -1);
    } else if (fingerY > viewportH - 90) {
      _startAutoScroll(scroll, 1);
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll(ScrollController scroll, int dir) {
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!scroll.hasClients) {
        _stopAutoScroll();
        return;
      }
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
    _edgeTurnCtrl.lastGlobalX = globalX;
    final w = MediaQuery.sizeOf(context).width;
    // 保持区滞回：链已启动时，右缘链 x>65%、左缘链 x<35% 持续翻页
    if (_edgeTurnCtrl.armed) {
      final keep = _edgeTurnCtrl.dir > 0
          ? globalX > w * 0.65
          : globalX < w * 0.35;
      if (keep) return;
      _edgeTurnCtrl.timer?.cancel();
      _edgeTurnCtrl.timer = null;
      _edgeTurnCtrl.dir = 0;
      _edgeTurnCtrl.armed = false;
    }
    if (globalX > w * 0.85) {
      _armEdgeTimer(1, w);
    } else if (globalX < w * 0.06) {
      _armEdgeTimer(-1, w);
    } else {
      _edgeTurnCtrl.timer?.cancel();
      _edgeTurnCtrl.timer = null;
      _edgeTurnCtrl.dir = 0;
      _edgeTurnCtrl.armed = false;
    }
  }

  void _armEdgeTimer(int dir, double w) {
    if (_edgeTurnCtrl.timer != null && _edgeTurnCtrl.dir == dir) return;
    _edgeTurnCtrl.timer?.cancel();
    _edgeTurnCtrl.dir = dir;
    _edgeTurnCtrl.timer = Timer(const Duration(milliseconds: 300), () {
      _edgeTurnCtrl.timer = null;
      _edgeTurnCtrl.armed = true;
      _edgeTurn(dir.toDouble());
      _armContinuation(dir, w);
    });
  }

  void _armContinuation(int dir, double w) {
    // 保持区续链（按方向）
    final keep = dir > 0
        ? _edgeTurnCtrl.lastGlobalX > w * 0.65
        : _edgeTurnCtrl.lastGlobalX < w * 0.35;
    if (keep) {
      _edgeTurnCtrl.timer = Timer(const Duration(milliseconds: 500), () {
        _edgeTurnCtrl.timer = null;
        _edgeTurn(dir.toDouble());
        _armContinuation(dir, w);
      });
    }
  }

  /// 落点兜底（同 WeekView）：Draggable 被 evict 后松手按 route 上下文
  /// 副本 + 指针位置落点（日视图单列即 _dragDay）
  Future<void> _handleDragDrop(Offset pos) async {
    if (dragDropped.value) {
      dragDropped.value = false;
      _clearDragSharedState();
      return;
    }
    final taskId = _dragTaskId;
    final info = _dragInfo;
    if (taskId == null || info == null) {
      _clearDragSharedState();
      return;
    }
    final day = _dragDay.value;
    // 时间轴主体顶部全局 y（各页 post-frame 上报，当前页最后写入）
    final localDy = pos.dy - dragAxisTopY.value;
    final startHour = effectiveStartHourFor(byDay: widget.byDay, days: [day]);
    final minutes = (startHour * 60 + localDy / pixelPerHour * 60)
        .roundToDouble()
        .clamp(startHour * 60.0, endHour * 60.0);
    final snapped = ((minutes / 10).round() * 10).clamp(
      startHour * 60,
      endHour * 60,
    );
    final target = AppClock.at(
      day.year,
      day.month,
      day.day,
      snapped ~/ 60,
      snapped % 60,
    );
    final start = DateUtilsEx.clampStartWithinDay(
      target,
      Duration(minutes: info.durationMinutes),
    );
    _clearDragSharedState();
    final db = ref.read(dbProvider);
    final task = await db.getTask(taskId);
    if (task == null) return;
    final notifier = ref.read(calendarControllerProvider.notifier);
    if (task.rrule.isNotEmpty) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('更改整个系列？'),
          content: Text(
            '「${task.title}」是重复任务。\n'
            '将把整个系列改为从 ${DateUtilsEx.timeCn(start)} 开始'
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
      if (ok == true) {
        await notifier.moveTaskToDateTimeSeries(taskId, start);
      }
    } else {
      await notifier.moveTaskToDateTime(taskId, start);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      itemCount: 40000,
      // A13：allowImplicitScrolling 预构建页在 widget 测试 teardown 时
      // 触发 deactivate 时序问题（NowLine Timer pending），暂不启用；
      // 丝滑翻页主要靠窗口缓存（翻页零 DB）+ byDay 分组 build 减负
      onPageChanged: (page) {
        _activePage.value = page;
        final day = AppClock.at(2000, 1, 1).add(Duration(days: page));
        // 外部跳日动画期间：onPageChanged 多次触发（round 变化），只同步
        // _dragDay 不回写 selectedDay（防回跳打断动画停在中间日）；到达
        // 目标页结束拦截（动画结束时 whenComplete 也会清理）
        if (_pendingExternalPage != null) {
          _dragDay.value = day;
          if (page == _pendingExternalPage) {
            _pendingExternalPage = null;
          }
          return;
        }
        _dragDay.value = day;
        widget.onDayChanged(day);
      },
      itemBuilder: (context, page) {
        final day = AppClock.at(2000, 1, 1).add(Duration(days: page));
        return AxisKeepAlive(
          child: TimeAxisView(
            pageIndex: page,
            activePage: _activePage,
            items: widget.items,
            byDay: widget.byDay,
            start: day,
            isWeek: false,
            selectedDay: widget.selectedDay,
            dragDay: _dragDay,
            edgeState: _edgeState,
            scrollOffsetShare: _sharedScrollOffset,
            onEdgeTurn: _edgeTurn,
            dragGlobalPos: dragGlobalPos,
            dragTaskId: dragTaskId,
            dragActiveDay: dragActiveDay,
            dragGhostInfo: dragGhostInfo,
            dragDropped: dragDropped,
            dragAxisTopY: dragAxisTopY,
            dragScrollCtrl: dragScrollCtrl,
            dragViewportTopY: dragViewportTopY,
            dragViewportH: dragViewportH,
            edgeTurnCtrl: _edgeTurnCtrl,
            onDragStartTracking: (taskId, pointer) =>
                _registerDragRoute(taskId, pointer),
          ),
        );
      },
    );
  }
}

/// 保持 PageView 子页存活（拖动跨页时状态不丢）
