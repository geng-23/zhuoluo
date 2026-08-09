import 'dart:async';

import 'package:flutter/gestures.dart';
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

/// 时间轴起始小时——显示范围内最早 timed 任务（非全天/非跨天/
/// 有计划时间）的开始小时，与默认值取小：只扩展不收缩，多数情况保持
/// 06:00 起点；有 06:00 前任务时起始点下移，任务不再隐形不可操作。
/// 丝滑翻页：改为按天分组数据驱动——此前遍历整个窗口 items
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
  final ValueNotifier<_DragGhostInfo?> dragGhostInfo =
      ValueNotifier<_DragGhostInfo?>(null);

  /// 共享边缘翻页控制器（连续翻周链跨页保持）
  final _EdgeTurnController _edgeTurnCtrl = _EdgeTurnController();

  /// 正常落点已处理标志（onAcceptWithDetails 设置——全局 route 的 up
  /// 兜底据此跳过，避免重复改期）
  final ValueNotifier<bool> dragDropped = ValueNotifier<bool>(false);

  // ---------- 全局指针事件驱动（跨页拖动：Draggable 被 evict 后仍可靠） ----------
  /// 拖动中注册到 pointerRouter 的指针（up/取消时移除）
  int? _dragPointer;

  /// 拖动任务 id 副本（松手/取消会清共享状态——落点兜底用）
  int? _dragTaskId;

  /// 拖动任务信息副本（同原因，落点兜底用）
  _DragGhostInfo? _dragInfo;

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
  /// （与 _DayColumn 内同名方法逻辑一致，共享 edgeTurnCtrl——本层为
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
    final minutes = (startHour * 60 + localDy / _pixelPerHour * 60)
        .roundToDouble()
        .clamp(startHour * 60.0, _endHour * 60.0);
    final snapped = ((minutes / 10).round() * 10).clamp(
      startHour * 60,
      _endHour * 60,
    );
    final target = DateTime(
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
      // 触发 deactivate 时序问题（_NowLine Timer pending），暂不启用；
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
        return _KeepAlive(
          child: _TimeAxisView(
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
  final ValueNotifier<_DragGhostInfo?> dragGhostInfo =
      ValueNotifier<_DragGhostInfo?>(null);

  /// 共享边缘翻页控制器（连续翻日链跨页保持）
  final _EdgeTurnController _edgeTurnCtrl = _EdgeTurnController();

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

  int _pageFor(DateTime d) =>
      DateTime(d.year, d.month, d.day).difference(DateTime(2000, 1, 1)).inDays;

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
    _dragDay.value = DateTime(
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
  _DragGhostInfo? _dragInfo;

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
    final minutes = (startHour * 60 + localDy / _pixelPerHour * 60)
        .roundToDouble()
        .clamp(startHour * 60.0, _endHour * 60.0);
    final snapped = ((minutes / 10).round() * 10).clamp(
      startHour * 60,
      _endHour * 60,
    );
    final target = DateTime(
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
      // 触发 deactivate 时序问题（_NowLine Timer pending），暂不启用；
      // 丝滑翻页主要靠窗口缓存（翻页零 DB）+ byDay 分组 build 减负
      onPageChanged: (page) {
        _activePage.value = page;
        final day = DateTime(2000, 1, 1).add(Duration(days: page));
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
        final day = DateTime(2000, 1, 1).add(Duration(days: page));
        return _KeepAlive(
          child: _TimeAxisView(
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
  final ValueNotifier<_DragGhostInfo?>? dragGhostInfo;
  final ValueNotifier<bool>? dragDropped;

  /// 本页时间轴主体顶部全局 y 上报（落点兜底换算基准）
  final ValueNotifier<double>? dragAxisTopY;

  /// 本页 scrollController + 视口顶全局 y + 视口高上报（翻页后
  /// Draggable evict 时全局 route 接管垂直自动滚动用）
  final ValueNotifier<ScrollController?>? dragScrollCtrl;
  final ValueNotifier<double>? dragViewportTopY;
  final ValueNotifier<double>? dragViewportH;

  /// 共享边缘翻页控制器（连续翻周链跨页保持）
  final _EdgeTurnController? edgeTurnCtrl;

  /// 拖动开始上报指针（WeekView/DayView 注册全局 route 用）
  final void Function(int taskId, int pointer)? onDragStartTracking;

  @override
  ConsumerState<_TimeAxisView> createState() => _TimeAxisViewState();
}

class _TimeAxisViewState extends ConsumerState<_TimeAxisView> {
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
    // _NowLine 自驱动，不再触发整个时间轴重建
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
                          // 合并为一次 load（此前 setSelectedDay+setView 两次）
                          ? () => notifier.setSelectedDayWithView(d, 'day')
                          // 日视图头部可点击跳转其他日期（此前点击无反应）
                          : () async {
                              final now = AppClock.now();
                              // 日视图可翻至 2000-01-01，当前显示日超界
                              // 会触发 DatePicker 断言崩溃，钳制到 [first, last]
                              //（前后各 60 年，覆盖日视图可翻范围）
                              final first = DateTime(now.year - 60);
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
                    _AllDayBar(
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
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            children: [
                              // 时间轴主体（18 行，6:00~23:00 线）
                              SizedBox(
                                key: _axisKey,
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 与 _DayColumnState.columnWidth 同口径
                                        // （扣除时间栏 44px 后均分）
                                        for (
                                          var i = 0;
                                          i < days.length;
                                          i++
                                        ) ...[
                                          Expanded(
                                            child: _DayColumn(
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
                                    _NowLine(
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
  bool _isTopArea(CalendarItem i) => _AllDayBar.isTopArea(i);

  /// 显示范围内（当周/当天）timed 任务的最早开始小时，
  /// 与默认 6 取小——只扩展不收缩（多数情况保持 06:00 起点）。
  int _effectiveStartHour(List<DateTime> days) =>
      effectiveStartHourFor(byDay: widget.byDay, days: days);

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

  /// 时间轴起始小时（与 _TimeAxisView 动态起始一致，红线随之下移）
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
      (byDay[_dayKey(day)] ?? const <CalendarItem>[]).where(isTopArea).toList();

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

/// 边缘翻页控制器（WeekView/DayView 持有，跨页共享）：
/// 连续翻周链的 Timer/方向/最后位置不随列重建丢失，
/// 离开边缘/松手时任意列都可统一取消
class _EdgeTurnController {
  Timer? timer;
  int dir = 0;
  double lastGlobalX = 0;

  /// 连续翻页链已启动（首次翻页 fire 后置位）：保持区内触摸点微漂移
  /// 不断链（"不间断翻页"）；移出保持区停链；松手/取消复位
  bool armed = false;
}

/// 拖动虚影渲染所需的任务信息（拖动开始时上报——
/// 跨周后任务不在当前视图 items 中，虚影据此渲染而非查视图数据）
class _DragGhostInfo {
  final String title;
  final int durationMinutes;
  final String color;
  final String listColor;

  const _DragGhostInfo({
    required this.title,
    required this.durationMinutes,
    required this.color,
    required this.listColor,
  });
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
    this.dragGlobalPos,
    this.dragTaskId,
    this.dragActiveDay,
    this.dragGhostInfo,
    this.dragDropped,
    this.edgeTurnCtrl,
    this.onDragStartTracking,
  });

  final DateTime day;
  final List<CalendarItem> items;
  final bool isWeek;

  /// 时间轴起始小时（动态——显示范围内最早 timed 任务决定，
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

  /// 共享拖拽状态（WeekView/DayView 持有——跨页后新列据此恢复虚影/胶囊；
  /// 此前为列局部状态，翻页后新列无虚影、无法连续拖动）
  final ValueNotifier<Offset?>? dragGlobalPos;
  final ValueNotifier<int?>? dragTaskId;
  final ValueNotifier<DateTime?>? dragActiveDay;
  final ValueNotifier<_DragGhostInfo?>? dragGhostInfo;

  /// 正常落点已处理标志（onAcceptWithDetails 设置——全局 route 的 up
  /// 兜底据此跳过，避免重复改期）
  final ValueNotifier<bool>? dragDropped;

  /// 共享边缘翻页控制器（连续翻周链跨页保持，可统一取消）
  final _EdgeTurnController? edgeTurnCtrl;

  /// 拖动开始上报指针（WeekView 注册全局 pointerRouter route 用）
  final void Function(int taskId, int pointer)? onDragStartTracking;

  @override
  ConsumerState<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends ConsumerState<_DayColumn> {
  /// 单列宽度（周视图 7 列、日视图 1 列，扣除左侧时间栏 44px）
  double get columnWidth => (widget.axisWidth - 44) / (widget.isWeek ? 7 : 1);

  /// dragGlobalPos 为 null（无共享状态）时的兜底 notifier
  static final ValueNotifier<Offset?> _noopPos = ValueNotifier<Offset?>(null);

  /// 列容器 GlobalKey（虚影/胶囊全局→局部坐标换算基准）
  final GlobalKey _columnKey = GlobalKey();

  /// 按下本列任务块的指针（拖动开始时上报 WeekView 注册全局 route）
  int _dragPointer = 0;

  // E7：拖动选时状态
  bool _dragSelecting = false;
  double? _dragStartY;
  double? _dragCurrentY;
  double? _selectionStartGlobalX;
  double? _selectionStartGlobalY;

  /// 拖选胶囊位置（列内局部坐标；拖动任务路径的胶囊/虚影由共享状态
  /// dragGlobalPos 驱动，见 Stack 渲染层）
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
  /// 三层防误触：
  /// 1. 边缘区：左缘收紧到屏幕最外 6%，右缘放宽到 15%（85% 外——周五列
  ///    任务块右缘约 85%，手指够得着；此前 94% 太窄几乎无法触发）
  /// 2. 进入边缘区需持续停留 300ms 才触发（快速拖过定位不翻页）
  /// 3. 连续翻页链（Timer/方向/位置）存共享控制器（跨页保持，见 _EdgeTurnController）

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

  /// 边缘翻周/日：进入边缘区停留 300ms 触发首次翻页；
  /// 翻页后若指针仍停边缘（保持区：右缘链 x>65%、左缘链 x<35%）→ 每
  /// 500ms 自动续翻（连续拖到多个周以后），触摸点微漂移不断链；
  /// 移出保持区（拖回中间定位）或松手（_clearDragState）即停止。
  /// Timer/方向/最后位置存共享控制器（跨页保持，任意列可取消）。
  void _maybeEdgeTurn(double globalX) {
    final onEdgeTurn = widget.onEdgeTurn;
    final state = widget.edgeState;
    final ctrl = widget.edgeTurnCtrl;
    if (onEdgeTurn == null || state == null || ctrl == null) return;
    ctrl.lastGlobalX = globalX;
    final w = MediaQuery.of(context).size.width;
    // 保持区滞回：链已启动时，右缘链 x>65%、左缘链 x<35% 持续翻页
    if (ctrl.armed) {
      final keep = ctrl.dir > 0 ? globalX > w * 0.65 : globalX < w * 0.35;
      if (keep) return;
      ctrl.timer?.cancel();
      ctrl.timer = null;
      ctrl.dir = 0;
      ctrl.armed = false;
      state.value = 0;
    }
    if (globalX > w * 0.85) {
      _armEdgeTimer(1, w, ctrl);
    } else if (globalX < w * 0.06) {
      _armEdgeTimer(-1, w, ctrl);
    } else {
      // 离开边缘区：取消计时（含连续链）
      ctrl.timer?.cancel();
      ctrl.timer = null;
      ctrl.dir = 0;
      ctrl.armed = false;
      state.value = 0;
    }
  }

  /// 长按选时默认是纵向动作。只有水平位移明显且确实是水平意图时，
  /// 才允许进入边缘翻页，避免周边列的轻微手抖触发翻页。
  void _maybeEdgeTurnForSelection(Offset globalPosition) {
    final startX = _selectionStartGlobalX;
    final startY = _selectionStartGlobalY;
    if (startX == null || startY == null) return;
    final dx = globalPosition.dx - startX;
    final dy = globalPosition.dy - startY;
    if (dx.abs() < 36 || dx.abs() <= dy.abs()) {
      _cancelSelectionEdgeTurn();
      return;
    }
    _maybeEdgeTurn(globalPosition.dx);
  }

  void _cancelSelectionEdgeTurn() {
    final ctrl = widget.edgeTurnCtrl;
    ctrl?.timer?.cancel();
    ctrl?.timer = null;
    ctrl?.dir = 0;
    ctrl?.armed = false;
    widget.edgeState?.value = 0;
  }

  /// 调度边缘翻页：首次 300ms 延迟（快速拖过定位不误翻）；
  /// 同向已有计时（含连续链）则不重复调度
  void _armEdgeTimer(int dir, double w, _EdgeTurnController ctrl) {
    if (ctrl.timer != null && ctrl.dir == dir) return;
    ctrl.timer?.cancel();
    ctrl.dir = dir;
    ctrl.timer = Timer(const Duration(milliseconds: 300), () {
      ctrl.timer = null;
      ctrl.armed = true;
      widget.edgeState?.value = dir;
      widget.onEdgeTurn?.call(dir.toDouble());
      _armContinuation(dir, w, ctrl);
    });
  }

  /// 连续翻页链：翻页后指针仍停保持区 → 500ms 后再翻，递归续链
  void _armContinuation(int dir, double w, _EdgeTurnController ctrl) {
    // 保持区续链（按方向）
    final keep = dir > 0
        ? ctrl.lastGlobalX > w * 0.65
        : ctrl.lastGlobalX < w * 0.35;
    if (keep) {
      ctrl.timer = Timer(const Duration(milliseconds: 500), () {
        ctrl.timer = null;
        widget.onEdgeTurn?.call(dir.toDouble());
        _armContinuation(dir, w, ctrl);
      });
    }
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _hintPos.dispose();
    // 选时路径（无全局 route 接管）：列被销毁（跨多周超 cacheExtent 被
    // evict）时取消共享连续翻页链 Timer（防 pending/幽灵翻页）。
    // 拖动任务路径的共享 timer 由全局 route 的 move/up 持续驱动与管理
    // （列 evict 后连续翻页链继续由全局 route 续链，松手时统一取消），
    // 此处不取消——否则手指不动时翻页链在 evict 处中断。
    if (_dragSelecting) {
      _cancelSelectionEdgeTurn();
    }
    super.dispose();
  }

  /// Draggable 全局坐标驱动（丝滑交互：边缘翻周/日不依赖 DragTarget 命中——
  /// 指针拖出列范围/屏幕边缘空白区仍可靠检测；此前基于 DragTarget.onMove，
  /// 一旦 onLeave 触发即失效）
  void _handleDragGlobal(Offset global) {
    // 共享拖拽位置（翻页后新列据此恢复虚影/胶囊）
    widget.dragGlobalPos?.value = global;
    _maybeEdgeTurn(global.dx);
    _checkVerticalAutoScroll(global.dy);
  }

  /// 统一清理拖拽状态（松手/改期完成：共享虚影/胶囊 + 边缘/自动滚动）
  void _clearDragState() {
    widget.dragTaskId?.value = null;
    widget.dragGlobalPos?.value = null;
    widget.dragActiveDay?.value = null;
    widget.dragGhostInfo?.value = null;
    _stopAutoScroll();
    final ctrl = widget.edgeTurnCtrl;
    ctrl?.timer?.cancel();
    ctrl?.timer = null;
    ctrl?.dir = 0;
    ctrl?.armed = false;
    widget.edgeState?.value = 0;
  }

  /// 拖动结束（松手）：统一清理（幂等，onAccept 后也会走）
  void _handleDragEnd() {
    _clearDragState();
  }

  /// Draggable 被 dispose（跨多周拖出 cacheExtent）/手势取消时的兜底：
  /// 只停本列自动滚动；**不清共享拖拽状态**——否则翻页 4-5 页后任务块
  /// 虚影/胶囊"闪退"回原位（Draggable State dispose 时 onDraggableCanceled
  /// 无条件触发，与真实手势取消共用此回调）。真实手势取消由全局 route
  /// 的 PointerCancelEvent → _clearDragSharedState 统一清理（不会残留）
  void _handleDraggableCanceled() {
    _stopAutoScroll();
  }

  /// 全局坐标 → 本列局部坐标（虚影/胶囊渲染换算）。
  /// 用列容器 GlobalKey（build 期间 State.context 的 RenderObject 尚未
  /// attach 返回 null——新列翻页后首次 build 时虚影会丢失）
  Offset? _localFromGlobal(Offset gpos) {
    final box = _columnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.globalToLocal(gpos);
  }

  /// 虚影/胶囊渲染换算兜底：列未布局（build 期间）时调度一帧后重算
  void _retryLocalAfterLayout() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// 是否显示在顶部置顶区（全天 / 无计划时间 / 跨天任务）
  @override
  Widget build(BuildContext context) {
    // 重叠分栏
    final blocks = _layoutOverlap(widget.items);
    final notifier = ref.read(calendarControllerProvider.notifier);
    return DragTarget<int>(
      key: _columnKey,
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        // 共享拖拽状态：任务 id + 悬停列（虚影/胶囊渲染由共享
        // dragGlobalPos 驱动，_handleDragGlobal 更新）
        widget.dragTaskId?.value = details.data;
        widget.dragActiveDay?.value = widget.day;
        // 注意：不再取消共享连续翻页链——onMove 由 avatar 悬停检测
        // 驱动，测试环境无 move 事件时也会触发（长按后/翻页后），
        // 无条件取消会让"拖任务到边缘连续翻页"断链；链的启停统一
        // 由 _maybeEdgeTurn 的保持区滞回管理（移出保持区才停链）
      },
      onLeave: (details) {
        // 注意：不再清共享拖拽状态——指针离开本列后虚影保留在
        // 活动列（边缘翻周由 Draggable 全局坐标继续驱动）；
        // 松手时由 _handleDragEnd 统一清理
        _stopAutoScroll();
        widget.edgeState?.value = 0; // 重置边缘滞回
      },
      onAcceptWithDetails: (details) async {
        // 正常落点已处理：全局 route 的 up 兜底据此跳过（避免重复改期）
        widget.dragDropped?.value = true;
        // 落点局部坐标 → 吸附 10 分钟 → 改期（含时分，支持跨天）。
        // 注意：details.offset 是相对拖拽锚点的偏移（SDK 内部
        // _lastOffset = 指针 − dragStartPoint），不能当全局坐标用；
        // 用共享 dragGlobalPos（Draggable 全局坐标）换算本列局部位置
        final gpos = widget.dragGlobalPos?.value;
        final box = context.findRenderObject() as RenderBox?;
        var dy = 0.0;
        if (box != null && gpos != null) {
          dy = box.globalToLocal(gpos).dy;
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
            _clearDragState();
            return;
          }
          await notifier.moveTaskToDateTimeSeries(details.data, target);
          // 拖动结束：清空状态让浮标消失
          _clearDragState();
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
        _clearDragState();
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
            _cancelSelectionEdgeTurn();
            Haptics.select();
            setState(() {
              _dragSelecting = true;
              _dragStartY = details.localPosition.dy;
              _dragCurrentY = details.localPosition.dy;
              _selectionStartGlobalX = details.globalPosition.dx;
              _selectionStartGlobalY = details.globalPosition.dy;
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
            _maybeEdgeTurnForSelection(details.globalPosition);
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
            _cancelSelectionEdgeTurn();
            if (!_dragSelecting) return;
            final start = _dragStartY ?? 0;
            final end = _dragCurrentY ?? start;
            _hintPos.value = null;
            setState(() {
              _dragSelecting = false;
              _dragStartY = null;
              _dragCurrentY = null;
              _selectionStartGlobalX = null;
              _selectionStartGlobalY = null;
            });
            // 长按未拖动（位移过小）→ 等价点击空白，打开默认时长
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
                      key: ValueKey(
                        'more-${b.item.task.id}-${b.item.instanceDate}',
                      ),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      top:
                          (b.spanEnd != null
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
                      key: ValueKey(
                        'blk-${b.item.task.id}-${b.item.instanceDate}',
                      ),
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
                          // 拖动中原任务块半透明由共享状态驱动（跨页返回一致）
                          dragTaskId: widget.dragTaskId,
                          // 边缘翻周/日 + 垂直自动滚动：Draggable 全局坐标驱动
                          onDragPosition: _handleDragGlobal,
                          onDragEnd: _handleDragEnd,
                          onDragCanceled: _handleDraggableCanceled,
                          onPointerDown: (p) => _dragPointer = p,
                          onDragStartedTask: (id) {
                            widget.dragTaskId?.value = id;
                            // 上报任务显示信息：跨周后视图 items 不含旧周
                            // 任务，虚影渲染据此（title/时长/颜色）
                            for (final it in widget.items) {
                              if (it.task.id == id) {
                                widget.dragGhostInfo?.value = _DragGhostInfo(
                                  title: it.task.title,
                                  durationMinutes: it.task.durationMinutes,
                                  color: it.task.color,
                                  listColor: it.listColor,
                                );
                                break;
                              }
                            }
                            // 上报指针：WeekView 注册全局 pointerRouter route
                            //（跨页事件驱动，Draggable 被 evict 后仍可靠）
                            widget.onDragStartTracking?.call(id, _dragPointer);
                          },
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
                // 拖动改期虚影：目标位置实时预览（最上层，跟随手指）。
                // 由共享拖拽状态驱动（dragGlobalPos/dragTaskId/dragActiveDay）——
                // 翻周/翻日后新列据此恢复虚影，可连续跨页拖动
                ValueListenableBuilder<Offset?>(
                  valueListenable: widget.dragGlobalPos ?? _noopPos,
                  builder: (context, gpos, _) {
                    if (gpos == null ||
                        widget.dragTaskId?.value == null ||
                        !_isActiveColumn()) {
                      return const SizedBox.shrink();
                    }
                    final local = _localFromGlobal(gpos);
                    if (local == null) {
                      _retryLocalAfterLayout(); // 列未布局：下一帧重算
                      return const SizedBox.shrink();
                    }
                    return AnimatedPositioned(
                      duration: const Duration(milliseconds: 80),
                      curve: Curves.easeOut,
                      // 虚影位置 = 实际写入（C5-1 回退后）的开始时间
                      top: _ghostTopFor(local.dy),
                      left: 2,
                      right: 2,
                      height: (_dragGhostHeight()),
                      child: _dragGhost(local.dy),
                    );
                  },
                ),
                // A13：拖动任务胶囊（共享状态驱动，跨页保持）
                ValueListenableBuilder<Offset?>(
                  valueListenable: widget.dragGlobalPos ?? _noopPos,
                  builder: (context, gpos, _) {
                    if (gpos == null ||
                        widget.dragTaskId?.value == null ||
                        !_isActiveColumn()) {
                      return const SizedBox.shrink();
                    }
                    final local = _localFromGlobal(gpos);
                    if (local == null) {
                      _retryLocalAfterLayout(); // 列未布局：下一帧重算
                      return const SizedBox.shrink();
                    }
                    final gStart = _draggedStartForMinutes(
                      _snapMinutesForY(local.dy),
                    );
                    return _buildHintCapsule(
                      local: local,
                      anchorY:
                          ((gStart.hour * 60 + gStart.minute) -
                              widget.startHour * 60) /
                          60 *
                          _pixelPerHour,
                      text: DateUtilsEx.timeCn(gStart),
                    );
                  },
                ),
                // A13：拖选胶囊（长按选时，列局部状态——选区跨页保持不在本次范围）
                ValueListenableBuilder<Offset?>(
                  valueListenable: _hintPos,
                  builder: (context, pos, _) {
                    if (pos == null || !_dragSelecting) {
                      return const SizedBox.shrink();
                    }
                    return _buildHintCapsule(
                      local: pos,
                      anchorY: _dragStartY ?? pos.dy,
                      text: _selectionHintText(),
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

  /// 拖动改期虚影：目标位置实时预览（半透明任务块 + 标题 + 时间）。
  /// [localY]：指针在本列内的 y（由共享全局位置换算）。
  /// 任务显示信息来自共享 dragGhostInfo（拖动开始时上报——跨周后
  /// 视图 items 不含旧周任务，不可再按 id 查询）
  Widget _dragGhost(double localY) {
    final info = widget.dragGhostInfo?.value;
    if (info == null) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final color =
        TaskColors.colorOf(info.color, brightness) ??
        colorFromHex(info.listColor);
    final onColor = TaskColors.textOn(color);
    final snapped = _snapMinutesForY(localY);
    // 虚影显示实际写入的开始时间（C5-1 回退后），所见即所得
    final start = _draggedStartForMinutes(snapped);
    final dur = info.durationMinutes;
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
              info.title,
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
    final info = widget.dragGhostInfo?.value;
    if (info == null) return _pixelPerHour;
    final h = info.durationMinutes / 60 * _pixelPerHour;
    return h < 32 ? 32 : h;
  }

  /// 拖动改期虚影的实际开始时间——落点分钟经 C5-1"时长不跨天"
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
    return widget.dragGhostInfo?.value?.durationMinutes;
  }

  /// 虚影在时间轴内的 top——基于实际写入（C5-1 回退后）的开始时间
  double _ghostTopFor(double gy) {
    final s = _draggedStartForMinutes(_snapMinutesForY(gy));
    return ((s.hour * 60 + s.minute) - widget.startHour * 60) /
            60 *
            _pixelPerHour -
        1;
  }

  /// E7：将拖动范围吸附到 10 分钟粒度
  /// 与 _snappedYRange 一致 clamp 到 [06:00, 23:00]——
  /// 此前顶部/底部 padding 区拖动可得 5:30/23:30，预览与结果不一致
  /// C5-2：两端同 clamp 到 23:00 时保证至少 10 分钟跨度
  (DateTime, DateTime) _snapRange(double y1, double y2) {
    final minutes1 =
        widget.startHour * 60 + (y1 < y2 ? y1 : y2) / _pixelPerHour * 60;
    final minutes2 =
        widget.startHour * 60 + (y1 < y2 ? y2 : y1) / _pixelPerHour * 60;
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

  /// 本列是否为共享拖拽的"活动列"（虚影/胶囊仅显示在活动列；
  /// 边缘翻周后由 WeekView/DayView._edgeTurn 更新为新页边缘列）
  bool _isActiveColumn() {
    final active = widget.dragActiveDay?.value;
    return active != null && DateUtilsEx.sameDay(active, widget.day);
  }

  /// 悬浮时间胶囊（拖动任务 + 长按拖选共用渲染）：
  /// [local] 胶囊锚定位置（列内局部），[anchorY] 垂直锚点（选区/虚影上端），
  /// 顶部空间不足时翻到锚点下方；水平按整个时间轴视口宽钳制（允许跨列绘制）。
  /// 垂直以屏幕坐标定位并钳制在 **ListView 视口** 内（列表滚动后胶囊
  /// 不被 AppBar 后遮挡/不被视口裁剪）；水平与手指错开（手指不挡胶囊）。
  Widget _buildHintCapsule({
    required Offset local,
    required double anchorY,
    required String text,
  }) {
    const capH = 28.0;
    const capW = 78.0;
    // 胶囊与锚点间距（防手指遮挡：手指接触半径约 22px，须大于半径 + 余量）
    const capGap = 48.0;
    // 水平错开量：胶囊中心与手指水平间距（手指不挡胶囊，比继续加高更自然）
    const capOffsetX = 36.0;
    final maxY = (_endHour - widget.startHour) * _pixelPerHour;
    final safeBottom = MediaQuery.paddingOf(context).bottom + 4;
    var top = anchorY - capH - capGap;
    // 屏幕内定位：列 Stack 顶部全局 y + 列内锚点 → 锚点屏幕 y，
    // 胶囊放锚点上方，超可见区顶则翻到锚点下方，再钳制在可见区
    //（可见区 = ListView 视口 ∩ 列 Stack——此前用 padding 当上界，
    // 列表滚动后胶囊被 clamp 到 AppBar 之后被完全遮挡）
    final box = _columnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      // 列尚未布局（如翻页后新列首帧）：本帧不渲染，下一帧重算——
      // 避免按列内坐标兜底渲染到屏幕外（滚动后列 Stack 顶部可能在视口上方）
      _retryLocalAfterLayout();
      return const SizedBox.shrink();
    }
    final axisTopGlobal = box.localToGlobal(Offset.zero).dy;
    final screenH = MediaQuery.sizeOf(context).height;
    final scrollable =
        Scrollable.of(context).context.findRenderObject() as RenderBox?;
    final viewportTop = scrollable != null && scrollable.hasSize
        ? scrollable.localToGlobal(Offset.zero).dy
        : axisTopGlobal;
    // 垂直可见区 = 视口顶 ∩ 列 Stack 顶（取靠下者）+ 安全边 4px
    final visibleTop = viewportTop + 4 > axisTopGlobal + 4
        ? viewportTop + 4
        : axisTopGlobal + 4;
    final axisBottom = axisTopGlobal + maxY;
    final screenBottom = screenH - capH - safeBottom;
    final visibleBottom = axisBottom - 4 < screenBottom
        ? axisBottom - 4
        : screenBottom;
    final anchorScreenY = axisTopGlobal + anchorY;
    var topScreen = anchorScreenY - capH - capGap;
    if (topScreen < visibleTop) topScreen = anchorScreenY + capGap;
    topScreen = topScreen.clamp(
      visibleTop,
      visibleBottom < visibleTop ? visibleTop : visibleBottom,
    );
    top = topScreen - axisTopGlobal;
    top = top.clamp(4.0, maxY - capH - 4);
    // A13：水平按整个时间轴视口宽 clamp（周视图单列仅约 50px，
    // 按列 clamp 会因 min>max 抛 ArgumentError 使整列崩溃；
    // 胶囊是浮层，允许跨列绘制）。
    // 列内 Positioned 坐标换算：视口内位置 = viewportLeft + 列内 dx，
    // 先钳制在视口内再减回列偏移——周日列胶囊右缘不再超出视口被裁
    final viewportW = columnWidth * (widget.isWeek ? 7 : 1);
    var left =
        (widget.viewportLeft + local.dx - capW / 2).clamp(
          4.0,
          viewportW - capW - 4,
        ) -
        widget.viewportLeft;
    // 水平错开：胶囊中心与手指水平重叠（< capOffsetX）时，向视口内
    // 空间大的一侧偏移（shift = 错开量 + 半宽——完全脱离手指投影）
    final fingerX = widget.viewportLeft + local.dx;
    final center = left + widget.viewportLeft + capW / 2;
    if ((center - fingerX).abs() < capOffsetX) {
      final rightRoom = viewportW - 4 - (fingerX + capW / 2);
      final leftRoom = fingerX - capW / 2 - 4;
      final shift = capOffsetX + capW / 2;
      if (rightRoom >= leftRoom) {
        left =
            (fingerX + shift).clamp(4.0, viewportW - capW - 4) -
            widget.viewportLeft;
      } else {
        left =
            (fingerX - shift - capW).clamp(4.0, viewportW - capW - 4) -
            widget.viewportLeft;
      }
    }
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
              Icon(Icons.schedule, size: 13, color: scheme.onInverseSurface),
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
      builder: (c) => QuickAddSheetWithDefaults(day, start: start, end: end),
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
      // 例外改期目标时刻（displayTime）优先，否则 planStart 时分
      final dt = i.displayTime;
      final s = ps == null
          ? DateTime(day.year, day.month, day.day)
          : dt != null
          ? DateTime(day.year, day.month, day.day, dt.hour, dt.minute)
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
        if (intervals[i].start.isBefore(minStart))
          minStart = intervals[i].start;
        if (intervals[i].end.isAfter(maxEnd)) maxEnd = intervals[i].end;
      }
      if (members.length <= 2) {
        var col = 0;
        for (final i in members) {
          result.add(
            OverlapBlock(item: sorted[i], left: col, total: members.length),
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
    this.onDragCanceled,
    this.onDragStartedTask,
    this.onPointerDown,
    this.dragTaskId,
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

  /// 拖动被取消/任务列被 evict 时兜底（见 onDraggableCanceled；仅停本列
  /// 自动滚动——共享拖拽状态由全局 route 统一管理，此处不清）
  final VoidCallback? onDragCanceled;

  /// 拖动开始回调（上报任务 id——共享拖拽状态据此显示虚影/胶囊）
  final ValueChanged<int>? onDragStartedTask;

  /// 按下指针上报（全局 pointerRouter 事件驱动用）
  final ValueChanged<int>? onPointerDown;

  /// 共享拖动任务 id（null 兜底时用 _noopTaskId）：
  /// 拖动中原任务块半透明由共享状态驱动——跨页翻走再返回原页时
  /// Draggable 已死（childWhenDragging 失效），据此保持半透明一致
  final ValueNotifier<int?>? dragTaskId;

  /// dragTaskId 为 null 时的兜底 notifier
  static final ValueNotifier<int?> _noopTaskId = ValueNotifier<int?>(null);

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
    // 共享状态驱动的"拖动中"半透明：跨页翻走再返回原页时 Draggable
    // 已死（childWhenDragging 失效），原任务块据此保持与同页拖动一致的
    // 不明显状态；同页拖动时 childWhenDragging 已生效，双源一致
    // Listener 捕获按下指针：拖动开始后 WeekView 注册全局 pointerRouter
    // route（跨页事件驱动——Draggable 被 evict/dispose 后回调失效的兜底）
    return ValueListenableBuilder<int?>(
      valueListenable: dragTaskId ?? _noopTaskId,
      builder: (context, draggingId, _) {
        final dimmed = draggingId == item.task.id;
        final shown = dimmed ? Opacity(opacity: 0.3, child: block) : block;
        return Listener(
          onPointerDown: (e) => onPointerDown?.call(e.pointer),
          child: LongPressDraggable<int>(
            data: item.task.id,
            onDragStarted: () {
              Haptics.select();
              // 上报任务 id：共享拖拽状态据此显示虚影/胶囊
              onDragStartedTask?.call(item.task.id);
            },
            // 边缘翻周/日：Draggable 全局坐标驱动（此前依赖 DragTarget.onMove，
            // 指针离开列范围即失效）
            onDragUpdate: (d) => onDragPosition?.call(d.globalPosition),
            onDragEnd: (_) => onDragEnd?.call(),
            // 兜底：拖动中任务所在列被 PageView evict（跨多周后超 cacheExtent）
            // 导致 Draggable State dispose（mounted=false）时 onDragEnd 不回调
            //（SDK 有 mounted 检查），onDraggableCanceled 无此限制——据此停
            // 本列自动滚动；**不清共享拖拽状态**（否则翻页 4-5 页后虚影/胶囊
            // 闪退）；共享状态由全局 route 的 up/cancel 统一清理
            onDraggableCanceled: (_, _) => onDragCanceled?.call(),
            // 拖动不显示悬浮块：目标位置由虚影（_dragGhost）实时预览
            feedback: Material(
              color: Colors.transparent,
              child: const SizedBox.shrink(),
            ),
            childWhenDragging: Opacity(opacity: 0.3, child: block),
            child: shown,
          ),
        );
      },
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
                // 先等待跳过写入完成，再弹撤销条（此前先弹条后
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
                MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: t.id)),
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
    // 日视图可翻到百年前，实例日期超界会触发 DatePicker 断言崩溃
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
    // 记录例外 ID，撤销时删除该例外（而非新增反向例外）
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
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    for (final item in dayItems)
                      ListTile(
                        dense: true,
                        // 完成态：不明显的灰色
                        tileColor: item.completed
                            ? Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest
                            : null,
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
                            color: item.completed
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : null,
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
      // 月视图可翻到很久以前，实例日期超界会触发 DatePicker 断言崩溃；
      // 范围前后各 60 年（覆盖日常改期，超界时钳制到边界）
      final first = DateTime(now.year - 60);
      final last = DateTime(now.year + 60);
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
      // 与弹层入口一致——改期保留/选择时分（此前只选日期丢时分，
      // 且更新既有例外时会覆盖之前带时分的改期）
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
