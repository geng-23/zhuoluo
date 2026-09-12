import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/theme/task_colors.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';
import 'package:zhuoluo/features/calendar/views.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 日历页：顶部迷你月历选日，左侧菜单切换视图与添加任务。
/// 左右边缘 15% 区域滑动切换底部 tab（左缘右滑 → 上一个，
/// 右缘左滑 → 下一个），中间区域滑动翻月/翻周/翻日。
/// 实现：视图铺满全屏，Stack 顶层为全屏透明监听层（_EdgeTabSwipeDetector，
/// HitTestBehavior.translucent 零遮挡）——起点在屏幕左右 15% 区域内、
/// 非长按（首次移动距 down <350ms）、位移 ≥24px 的滑动切换底部 tab；
/// 中间 70% 区域滑动仍由 PageView 翻月/翻周/翻日；
/// 任务块点击/长按拖动完全不受影响。
/// 注意：检测层为 RawGestureDetector + 自定义识别器，边缘快速横向滑动
/// 会抢占手势竞技场（下层 PageView 不再翻页）——切 tab 与翻页互斥，
/// 避免返回日历后发现月/周/日范围被连带翻动。
class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({
    super.key,
    this.isActive = true,
    this.onNavigateLeft,
    this.onNavigateRight,
  });

  /// IndexedStack 中只有当前日历 Tab 可以接管系统返回键。
  final bool isActive;

  /// 屏幕左边缘向右滑（切到上一个 tab，如任务）
  final VoidCallback? onNavigateLeft;

  /// 屏幕右边缘向左滑（切到下一个 tab，如四象限）
  final VoidCallback? onNavigateRight;

  static final GlobalKey<ScaffoldState> scaffoldKey =
      GlobalKey<ScaffoldState>();

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  bool _showMiniMonth = false;
  DateTime? _monthReturnDay;
  late DateTime _miniMonth = AppClock.at(
    AppClock.now().year,
    AppClock.now().month,
    1,
  );

  void _closeMiniMonth() {
    if (_showMiniMonth) setState(() => _showMiniMonth = false);
  }

  void _openDrawer() {
    _closeMiniMonth();
    CalendarPage.scaffoldKey.currentState?.openDrawer();
  }

  void _returnToMonth(CalendarController notifier) {
    final day = _monthReturnDay;
    if (day == null) return;
    setState(() => _monthReturnDay = null);
    notifier.setSelectedDayWithView(day, 'month');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(calendarControllerProvider);
    final notifier = ref.read(calendarControllerProvider.notifier);
    final canReturn = state.view == 'day' && _monthReturnDay != null;
    return PopScope(
      canPop: !widget.isActive || (!_showMiniMonth && !canReturn),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !widget.isActive) return;
        if (CalendarPage.scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.of(context).pop();
          return;
        }
        if (_showMiniMonth) {
          _closeMiniMonth();
        } else if (canReturn) {
          _returnToMonth(notifier);
        }
      },
      child: Scaffold(
        key: CalendarPage.scaffoldKey,
        // 禁用抽屉边缘拖拽，保留边缘切 Tab 的原有手势。
        drawerEdgeDragWidth: 0,
        appBar: AppBar(
          leading: canReturn
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回月视图',
                  onPressed: () => _returnToMonth(notifier),
                )
              : IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: '日历菜单',
                  onPressed: _openDrawer,
                ),
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
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(
                  _showMiniMonth
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 22,
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
            if (canReturn)
              IconButton(
                icon: const Icon(Icons.menu),
                tooltip: '日历菜单',
                onPressed: _openDrawer,
              ),
          ],
        ),
        drawer: _CalendarDrawer(
          state: state,
          onViewChanged: (v) {
            setState(() => _monthReturnDay = null);
            _closeMiniMonth();
            notifier.setView(v);
          },
          onAdd: () => _openQuickAdd(context, ref),
          onPickDate: (d) => notifier.setSelectedDay(d),
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
                                  setState(() => _monthReturnDay = d);
                                  notifier.setSelectedDayWithView(d, 'day');
                                },
                                // 长按 = 快速添加（与点按预览区分开，
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
            // 全屏透明监听层（零遮挡）：边缘 15% 区滑动切 tab
            Positioned.fill(
              child: _EdgeTabSwipeDetector(
                onSwipeRight: widget.onNavigateLeft,
                onSwipeLeft: widget.onNavigateRight,
              ),
            ),
            if (_showMiniMonth)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeMiniMonth,
                  child: const ColoredBox(color: Colors.transparent),
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

  /// E9：标题随当前视图变化
  String _titleFor(CalendarState state) {
    final d = state.selectedDay;
    switch (state.view) {
      case 'month':
        return DateUtilsEx.monthCn(state.displayedMonth);
      case 'week':
        final monday = DateUtilsEx.mondayOf(d);
        final sunday = AppClock.addCalendarDays(monday, 6);
        // 跨月周（如 8/31-9/6）拆分显示，此前"8月 31-6日"误导
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

  void _openQuickAdd(
    BuildContext context,
    WidgetRef ref, {
    DateTime? initialDay,
  }) {
    final day = initialDay ?? AppClock.now();
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

/// 边缘滑动切 tab 检测层（丝滑交互，零遮挡）：
/// RawGestureDetector（HitTestBehavior.translucent——自身监听且下层正常交互），
/// 判定条件（全部满足才切 tab）：
/// 1. 指针起点在屏幕左右 15% 区域内（中间 70% 区域滑动仍由 PageView 翻页）
/// 2. 非长按：首次位移距按下 <350ms（长按拖动任务/长按选时不受影响）
/// 3. 累计绝对水平位移 ≥16px（不依赖速度，慢速滑动也可触发）
/// 4. 横向意图：水平位移明显大于垂直位移（abs(dx) > abs(dy)*1.5），
///    纵向滚动/斜向移动的横向抖动不视为切 tab 意图
/// 右滑 → [onSwipeRight]（左缘），左滑 → [onSwipeLeft]（右缘）。
/// 拖动任务到边缘翻周/日由 Draggable 全局坐标驱动（views.dart），互不干扰。
///
/// 关键：与旧实现（全屏 Listener 被动监听）不同，本识别器**参与手势竞技场**——
/// 判定为边缘快速横向滑动时立即 accepted 抢占，下层 PageView（月/周/日）
/// 收不到该手势，切 tab 不再连带翻页（修复"返回日历发现视图范围变了"）；
/// 非边缘滑动/长按/点击则 rejected 让位，行为与旧实现一致。
class _EdgeTabSwipeDetector extends StatefulWidget {
  const _EdgeTabSwipeDetector({this.onSwipeRight, this.onSwipeLeft});

  final VoidCallback? onSwipeRight;
  final VoidCallback? onSwipeLeft;

  @override
  State<_EdgeTabSwipeDetector> createState() => _EdgeTabSwipeDetectorState();
}

class _EdgeTabSwipeDetectorState extends State<_EdgeTabSwipeDetector> {
  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _EdgeTabSwipeRecognizer:
            GestureRecognizerFactoryWithHandlers<_EdgeTabSwipeRecognizer>(
              () => _EdgeTabSwipeRecognizer(),
              (instance) {
                instance
                  ..screenWidth = MediaQuery.sizeOf(context).width
                  ..onSwipeRight = widget.onSwipeRight
                  ..onSwipeLeft = widget.onSwipeLeft;
              },
            ),
      },
      child: const SizedBox.expand(),
    );
  }
}

/// 边缘滑动切 tab 识别器：起点在屏幕左右 15% 区、350ms 内快速横向拖动时
/// 立即赢得手势竞技场（下层 PageView 不再翻月/周/日），抬手满足条件才切 tab。
class _EdgeTabSwipeRecognizer extends OneSequenceGestureRecognizer {
  /// 起点判定区：屏幕左右各 15%（收窄——边缘区过大易与拖动任务/选时误触）
  static const double _edgeZone = 0.15;

  /// 触发位移阈值（px）
  static const double _triggerDx = 16;

  /// 横向意图比例：abs(dx) 须明显大于 abs(dy) 才视为切 tab（抗纵向抖动）
  static const double _minDxRatio = 1.5;

  /// 抢占 slop：水平位移超过此值即赢得竞技场（远小于 PageView 翻页距离，
  /// 一旦抢占 PageView 即收不到手势，切 tab 不再连带翻页）。
  /// 必须小于平台 touchSlop（Android 设备约 8-16px，真机实测 ~10px）——
  /// 若大于平台 slop，小步滑动时 PageView 的横向拖拽先跨过自身阈值
  /// 抢先 accepted，本识别器被判负（真机实测月视图右缘滑动被抢走）。
  static const double _slop = 4;

  /// 长按判定窗口：首次移动距按下超过此值 = 长按（拖动/选时），让位不切 tab
  static const Duration _longPressWindow = Duration(milliseconds: 350);

  /// 屏幕宽度（RawGestureDetector initialize 每次 build 更新，适配旋转）
  double screenWidth = 0;
  VoidCallback? onSwipeRight;
  VoidCallback? onSwipeLeft;

  Offset? _downPos;
  DateTime? _downTime;
  DateTime? _firstMoveAt;
  double _dx = 0;
  double _dy = 0;
  bool _inEdgeZone = false;
  bool _accepted = false;
  Timer? _timer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // 已有活动指针（多指）时忽略新按下——单指边缘手势语义
    if (_downPos != null) return;
    startTrackingPointer(event.pointer, event.transform);
    final w = screenWidth;
    final zone = w * _edgeZone;
    _downPos = event.position;
    _downTime = DateTime.now();
    _firstMoveAt = null;
    _dx = 0;
    _dy = 0;
    _accepted = false;
    _inEdgeZone = event.position.dx < zone || event.position.dx > w - zone;
    // 起点不在边缘区 → 立即让位（中间区滑动由 PageView 翻页）
    if (!_inEdgeZone) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    // 边缘区：350ms 内无快速横向移动 → 让位（长按拖动/慢滑由下层接管）
    _timer = Timer(_longPressWindow, () {
      resolve(GestureDisposition.rejected);
    });
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      final down = _downPos;
      if (down == null) return;
      _firstMoveAt ??= DateTime.now();
      // 绝对位移（相对按下点）而非 delta 累加——抖动不会逐次累积
      _dx = event.position.dx - down.dx;
      _dy = event.position.dy - down.dy;
      // 快速横向意图（位移超 slop 且 dx 明显大于 dy）→ 抢占手势，
      // PageView 收不到该手势，切 tab 不再连带翻页
      if (!_accepted &&
          _dx.abs() > _slop &&
          _dx.abs() > _dy.abs() * _minDxRatio) {
        _accepted = true;
        _timer?.cancel();
        resolve(GestureDisposition.accepted);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _finish(event);
    }
  }

  void _finish(PointerEvent event) {
    _timer?.cancel();
    if (_accepted) {
      final down = _downPos;
      final downTime = _downTime;
      final firstMove = _firstMoveAt;
      if (down != null && downTime != null && firstMove != null) {
        if (_dx.abs() >= _triggerDx && _dx.abs() > _dy.abs() * _minDxRatio) {
          final w = screenWidth;
          if (down.dx < w * _edgeZone && _dx > 0) {
            onSwipeRight?.call();
          } else if (down.dx > w * (1 - _edgeZone) && _dx < 0) {
            onSwipeLeft?.call();
          }
        }
      }
    } else {
      // 未抢占（点击/非横向）→ 弃权，让下层（tap/滚动/长按）获胜
      resolve(GestureDisposition.rejected);
    }
    stopTrackingPointer(event.pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _timer?.cancel();
    _reset();
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _timer?.cancel();
    _reset();
  }

  void _reset() {
    _downPos = null;
    _downTime = null;
    _firstMoveAt = null;
    _dx = 0;
    _dy = 0;
    _inEdgeZone = false;
    _accepted = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'edge tab swipe';
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
                      onPickDate(AppClock.at(m.year, m.month - 1, 1));
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
                      onPickDate(AppClock.at(m.year, m.month + 1, 1));
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
          // 六行月份也随可用高度收缩，任务摘要按格高降级。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rows = totalCells ~/ 7;
              final cellH = (constraints.maxHeight / rows)
                  .floorToDouble()
                  .clamp(48.0, 320.0);
              final itemLimit = cellH >= 76
                  ? _monthMaxItems
                  : cellH >= 56
                  ? 1
                  : 0;
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
                                fontSize: 13,
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
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final item in dayItems.take(itemLimit))
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 1),
                                      child: _MonthTaskLine(item: item),
                                    ),
                                  ),
                                if (itemLimit > 0 &&
                                    dayItems.length > itemLimit)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                              .withValues(alpha: 0.6),
                                          borderRadius: AppRadius.pill,
                                        ),
                                        child: Text(
                                          '+${dayItems.length - itemLimit}',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onPrimaryContainer,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (itemLimit == 0 && dayItems.isNotEmpty)
                                  Container(
                                    width: 6,
                                    height: 6,
                                    margin: const EdgeInsets.only(top: 3),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colorFromHex(
                                        dayItems.first.listColor,
                                      ),
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

class _MonthTaskLine extends StatelessWidget {
  const _MonthTaskLine({required this.item});

  final CalendarItem item;

  @override
  Widget build(BuildContext context) {
    final t = item.task;
    final done = item.completed;
    final listColor = colorFromHex(item.listColor);
    final scheme = Theme.of(context).colorScheme;
    // 谷歌日历风格：实心色块（任务色）+ 自动黑白文字；
    // 完成态用主题容器灰并划线降权
    final color = done ? scheme.surfaceContainerHighest : listColor;
    final textColor = done
        ? scheme.onSurfaceVariant
        : TaskColors.textOn(listColor);
    const radius = 6.0;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      // LayoutBuilder：按格子均分高度尽量多行显示标题
      // （月视图格子小，通常 1-2 行，长标题不再过早截断）
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : 28.0;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                t.title,
                maxLines: (h / 14).floor().clamp(1, 2),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
