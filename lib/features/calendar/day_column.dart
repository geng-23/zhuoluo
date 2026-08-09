import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/theme/task_colors.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/core/utils/task_ext.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/features/calendar/calendar_axis.dart';
import 'package:zhuoluo/features/calendar/calendar_sheets.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';

class EdgeTurnController {
  Timer? timer;
  int dir = 0;
  double lastGlobalX = 0;

  /// 连续翻页链已启动（首次翻页 fire 后置位）：保持区内触摸点微漂移
  /// 不断链（"不间断翻页"）；移出保持区停链；松手/取消复位
  bool armed = false;
}

/// 拖动虚影渲染所需的任务信息（拖动开始时上报——
/// 跨周后任务不在当前视图 items 中，虚影据此渲染而非查视图数据）


class DragGhostInfo {
  final String title;
  final int durationMinutes;
  final String color;
  final String listColor;

  const DragGhostInfo({
    required this.title,
    required this.durationMinutes,
    required this.color,
    required this.listColor,
  });
}

/// 单日列（E7：长按拖动选择时间区间创建任务）


class DayColumn extends ConsumerStatefulWidget {
  const DayColumn({
    super.key,
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
    this.dragViewportTopY,
    this.scrollOffsetShare,
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
  final ValueNotifier<DragGhostInfo?>? dragGhostInfo;

  /// 正常落点已处理标志（onAcceptWithDetails 设置——全局 route 的 up
  /// 兜底据此跳过，避免重复改期）
  final ValueNotifier<bool>? dragDropped;

  /// 时间轴视口顶部全局 y（WeekView/DayView 持有，跨页稳定）。
  /// 虚影/落点换算用它 + 共享滚动 offset 推算内容 y，
  /// 不依赖当前页自身 offset 的瞬态（翻页恢复前的跳变）
  final ValueNotifier<double>? dragViewportTopY;

  /// 共享垂直滚动位置（跨页稳定：翻页时保持旧值，不被新页瞬态污染）。
  /// 与 dragViewportTopY 配合计算内容 y
  final ValueNotifier<double>? scrollOffsetShare;

  /// 共享边缘翻页控制器（连续翻周链跨页保持，可统一取消）
  final EdgeTurnController? edgeTurnCtrl;

  /// 拖动开始上报指针（WeekView 注册全局 pointerRouter route 用）
  final void Function(int taskId, int pointer)? onDragStartTracking;

  @override
  ConsumerState<DayColumn> createState() => DayColumnState();
}

class DayColumnState extends ConsumerState<DayColumn> {
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
  /// 3. 连续翻页链（Timer/方向/位置）存共享控制器（跨页保持，见 EdgeTurnController）

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
    } else if (globalX < w * 0.12) {
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
  void _armEdgeTimer(int dir, double w, EdgeTurnController ctrl) {
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
  void _armContinuation(int dir, double w, EdgeTurnController ctrl) {
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

  /// 手指全局坐标 → 时间轴内容坐标（相对轴顶部，含滚动 offset）。
  /// 优先用跨页稳定的「视口顶部 + 轴顶部 padding + 共享滚动 offset」，
  /// 避免依赖当前列自身 offset（翻页后新页 offset 从 0 恢复共享值的
  /// 瞬态会让列容器坐标换算偏上，落点/虚影跳变）。
  /// 共享基准未就绪（视口从未上报，值为初始 0）时回退到本列容器
  /// transform（offset 恢复后恒正确），避免返回 null 导致虚影消失。
  /// 返回 null 表示两种换算都不可用（列未布局）。
  double? _stableContentDy(Offset gpos) {
    final viewportTop = widget.dragViewportTopY?.value;
    if (viewportTop != null && viewportTop > 0) {
      final sharedOffset = widget.scrollOffsetShare?.value ?? 0;
      return gpos.dy - viewportTop - axisTopPadding + sharedOffset;
    }
    return _localFromGlobal(gpos)?.dy;
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
        // 连续翻页链激活（armed）时，活动列由定时链（_edgeTurn）单一
        // 权威驱动——onMove 不再覆盖，否则翻页动画中手指悬停的中间/
        // 旧页列会把 dragActiveDay 钉到将 evict 的列，虚影随之消失
        if (widget.edgeTurnCtrl?.armed == true) return;
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
        // 长按未移动（无 move 事件，dragGlobalPos 为 null）时没有有效
        // 落点坐标——视为"未拖动"，取消改期。此前 dy=0 兜底会把
        // 落点算成 06:00（时间轴最顶部），长按不动松手任务被误改期。
        if (gpos == null) {
          _clearDragState();
          return;
        }
        // 稳定基准换算内容 y：不依赖本列自身 scroll offset（跨页翻页
        // 恢复前的瞬态会让落点偏上）；基准未就绪时取消改期
        final dy = _stableContentDy(gpos);
        if (dy == null) {
          _clearDragState();
          return;
        }
        final minutes = (widget.startHour * 60 + dy / pixelPerHour * 60)
            .roundToDouble()
            .clamp(widget.startHour * 60.0, endHour * 60.0);
        final snapped = ((minutes / 10).round() * 10).clamp(
          widget.startHour * 60,
          endHour * 60,
        );
        final d = widget.day; // 改期落点 = 落点所在列的真实日期（翻页后为新页列）
        final target = AppClock.at(
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
            final minutes = widget.startHour * 60 + _tapY / pixelPerHour * 60;
            final tapped = ((minutes / 10).round() * 10)
                .clamp(widget.startHour * 60, endHour * 60 - 60)
                .toInt();
            final dayStart = AppClock.at(
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
          child: SizedBox(
            height: (endHour - widget.startHour) * pixelPerHour,
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
                        child: MoreBlock(
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
                        child: TaskBlock(
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
                                widget.dragGhostInfo?.value = DragGhostInfo(
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
                    final dy = _stableContentDy(gpos);
                    if (dy == null) {
                      _retryLocalAfterLayout(); // 基准未就绪：下一帧重算
                      return const SizedBox.shrink();
                    }
                    return AnimatedPositioned(
                      duration: const Duration(milliseconds: 80),
                      curve: Curves.easeOut,
                      // 虚影位置 = 实际写入（C5-1 回退后）的开始时间
                      top: _ghostTopFor(dy),
                      left: 2,
                      right: 2,
                      height: (_dragGhostHeight()),
                      child: _dragGhost(dy),
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
                    // 垂直用稳定基准（local 仅用于水平 dx）
                    final dy = _stableContentDy(gpos) ?? local.dy;
                    final gStart = _draggedStartForMinutes(
                      _snapMinutesForY(dy),
                    );
                    return _buildHintCapsule(
                      local: local,
                      anchorY:
                          ((gStart.hour * 60 + gStart.minute) -
                              widget.startHour * 60) /
                          60 *
                          pixelPerHour,
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
    final minutes = (widget.startHour * 60 + y / pixelPerHour * 60)
        .roundToDouble()
        .clamp(widget.startHour * 60.0, endHour * 60.0);
    return ((minutes / 10).round() * 10)
        .clamp(widget.startHour * 60, endHour * 60)
        .round();
  }

  /// 虚影高度（被拖任务时长对应；不足 30 分钟按 30 分钟，与实块一致）
  double _dragGhostHeight() {
    final info = widget.dragGhostInfo?.value;
    if (info == null) return pixelPerHour;
    final h = info.durationMinutes / 60 * pixelPerHour;
    return h < 32 ? 32 : h;
  }

  /// 拖动改期虚影的实际开始时间——落点分钟经 C5-1"时长不跨天"
  /// 回退后（22:30 拖 2h 任务实际写入 21:00），预览（虚影/胶囊）与
  /// 写入端 moveTaskToDateTime 必须一致，否则所见非所得。
  DateTime _draggedStartForMinutes(int minutes) {
    final durMin = _draggedDurationMinutes() ?? 60;
    return DateUtilsEx.clampStartWithinDay(
      AppClock.at(
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
            pixelPerHour -
        1;
  }

  /// E7：将拖动范围吸附到 10 分钟粒度
  /// 与 _snappedYRange 一致 clamp 到 [06:00, 23:00]——
  /// 此前顶部/底部 padding 区拖动可得 5:30/23:30，预览与结果不一致
  /// C5-2：两端同 clamp 到 23:00 时保证至少 10 分钟跨度
  (DateTime, DateTime) _snapRange(double y1, double y2) {
    final minutes1 =
        widget.startHour * 60 + (y1 < y2 ? y1 : y2) / pixelPerHour * 60;
    final minutes2 =
        widget.startHour * 60 + (y1 < y2 ? y2 : y1) / pixelPerHour * 60;
    var snapped1 = ((minutes1 / 10).round() * 10)
        .clamp(widget.startHour * 60, endHour * 60)
        .toInt();
    final snapped2 = ((minutes2 / 10).round() * 10)
        .clamp(widget.startHour * 60, endHour * 60)
        .toInt();
    // 两端相等（拖到底部边界）→ 起点回退 10 分钟
    if (snapped2 <= snapped1) {
      snapped1 = (snapped2 - 10).clamp(widget.startHour * 60, endHour * 60);
    }
    final d = _targetDay;
    return (
      AppClock.at(d.year, d.month, d.day, snapped1 ~/ 60, snapped1 % 60),
      AppClock.at(d.year, d.month, d.day, snapped2 ~/ 60, snapped2 % 60),
    );
  }

  /// 将 y 坐标区间吸附到 10 分钟粒度（预览高亮区用，与 _snapRange 一致）
  (double, double) _snappedYRange(double y1, double y2) {
    double snap(double y) {
      final minutes = widget.startHour * 60 + y / pixelPerHour * 60;
      final snapped = ((minutes / 10).round() * 10).clamp(
        widget.startHour * 60,
        endHour * 60,
      );
      return (snapped - widget.startHour * 60) / 60 * pixelPerHour;
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
    final maxY = (endHour - widget.startHour) * pixelPerHour;
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
    // ：displayTime/planStart 为 DB 读回值，取时分前按应用时区解释
    final dt = item.displayTime;
    final ps = item.task.planStart;
    final minutes = dt != null
        ? AppClock.asApp(dt).hour * 60 + AppClock.asApp(dt).minute
        : ps == null
        ? 0
        : AppClock.asApp(ps).hour * 60 + AppClock.asApp(ps).minute;
    return (minutes - widget.startHour * 60) / 60 * pixelPerHour;
  }

  double _heightFor(CalendarItem item) {
    final dur = item.task.durationMinutes;
    final h = dur / 60 * pixelPerHour;
    // A13：不足 30 分钟的任务按 30 分钟（32px）显示，保证块内文字可读
    return h < 32 ? 32 : h;
  }

  /// 组区间 y 坐标换算（+N 徽标定位用）
  double _topForSpan(DateTime s) {
    final minutes = s.hour * 60 + s.minute;
    return (minutes - widget.startHour * 60) / 60 * pixelPerHour;
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
    final intervals = <Interval>[];
    for (final i in sorted) {
      // ：DB 读回值取字段前统一按应用时区解释
      final psA = i.task.planStart == null
          ? null
          : AppClock.asApp(i.task.planStart!);
      final peA = i.task.planEnd == null
          ? null
          : AppClock.asApp(i.task.planEnd!);
      final da = AppClock.asApp(i.instanceDate);
      final dtA = i.displayTime == null ? null : AppClock.asApp(i.displayTime!);
      final s = psA == null
          ? AppClock.at(da.year, da.month, da.day)
          : dtA != null
          ? AppClock.at(da.year, da.month, da.day, dtA.hour, dtA.minute)
          : AppClock.at(da.year, da.month, da.day, psA.hour, psA.minute);
      final endTime = peA ?? psA?.add(const Duration(hours: 1));
      var e = endTime == null
          ? s.add(const Duration(hours: 1))
          : dtA != null
          ? s.add(endTime.difference(psA ?? endTime))
          : AppClock.at(
              da.year,
              da.month,
              da.day,
              endTime.hour,
              endTime.minute,
            );
      if (e.isBefore(s)) e = e.add(const Duration(days: 1)); // 跨天（22:00-02:00）
      intervals.add(Interval(s, e));
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
        if (intervals[i].start.isBefore(minStart)) {
          minStart = intervals[i].start;
        }
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



class Interval {
  final DateTime start;
  final DateTime end;

  Interval(this.start, this.end);
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


class MoreBlock extends StatelessWidget {
  const MoreBlock({
    super.key,required this.count, required this.day});

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


class TaskBlock extends ConsumerWidget {
  const TaskBlock({
    super.key,
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
    final heightDp = durMinutes / 60 * pixelPerHour;
    final lines = (heightDp / 14).floor();
    return lines.clamp(1, 3);
  }
}

/// 实例操作弹层（周/日视图任务块点击弹出；月视图经日预览弹层）
