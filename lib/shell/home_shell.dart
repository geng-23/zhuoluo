import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/features/calendar/calendar_page.dart';
import 'package:zhuoluo/features/profile/habit_page.dart';
import 'package:zhuoluo/features/profile/profile_page.dart';
import 'package:zhuoluo/features/profile/quadrant_page.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';
import 'package:zhuoluo/features/task/task_page.dart';
/// 四栏主壳（任务 / 日历 / 四象限 / 我的）
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _tab = 0;
  /// 用户是否已手动切换 Tab（_restoreTab 恢复结果不得覆盖手动选择）
  bool _tabChanged = false;
  StreamSubscription<NotificationTap>? _tapSub;
  /// A1：懒加载页面缓存——仅首次访问时创建，之后保留 State
  /// （IndexedStack 保留状态的前提是子树不因 key 变化重建）
  final List<Widget?> _pages = List<Widget?>.filled(4, null);

  void _switchTo(int i) {
    if (i < 0 || i > 3) return;
    _tabChanged = true;
    setState(() => _tab = i);
    ref.read(settingsProvider).set('lastTab', '$i');
  }

  Widget _buildPage(int i) => switch (i) {
    0 => TaskPage(onNavigateNext: () => _switchTo(1)),
    1 => CalendarPage(
      // 边缘滑动切 tab：左缘右滑 → 任务；右缘左滑 → 四象限
      onNavigateLeft: () => _switchTo(0),
      onNavigateRight: () => _switchTo(2),
    ),
    2 => QuadrantPage(
      onNavigateLeft: () => _switchTo(1),
      onNavigateRight: () => _switchTo(3),
    ),
    _ => ProfilePage(onNavigateLeft: () => _switchTo(2)),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreTab();
    // 通知点击深链定位：'t{taskId}' 任务详情 / 'h{habitId}' 习惯页；
    // actionId：贪睡（snooze）/已完成（done）按钮，处理后不导航
    _tapSub = ref.read(notificationServiceProvider).tapStream.listen((tap) {
      if (!mounted) return;
      _handleTap(tap);
    });
    // 冷启动深链——进程被杀后点通知启动 App，payload 不经 onTap 回调，
    // 需消费 init 时捕获的启动 payload（同步执行，无竞态）
    final launchTap = ref.read(notificationServiceProvider).consumeLaunchTap();
    if (launchTap != null) {
      _handleTap(launchTap);
    }
  }

  /// 通知 tap 深链统一入口：
  /// - actionId 'snooze'：贪睡 10 分钟，不导航
  /// - actionId 'done'：完成指定任务/实例，不导航
  /// - 正文点击：'t{taskId}' 打开任务详情（含提醒定位信息时弹延后选择）/
  ///   'h{habitId}' 打开习惯页
  void _handleTap(NotificationTap tap) {
    if (!mounted) return;
    final payload = tap.payload;
    if (payload == null) return;
    final nav = Navigator.of(context, rootNavigator: true);
    if (payload.startsWith('h')) {
      // 5.4：携带习惯 ID 定位到具体习惯（此前只打开通用习惯页）
      final id = int.tryParse(payload.substring(1));
      if (id == null) return;
      nav.push(
        MaterialPageRoute(
          builder: (_) => HabitPage(initialHabitId: id),
        ),
      );
      return;
    }
    final info = parseReminderTap(payload);
    if (info == null) return;
    // 按钮 action：贪睡/已完成统一走处理函数（前台 App 内也直接生效）
    if (tap.actionId == NotificationService.snoozeAction ||
        tap.actionId == NotificationService.doneAction) {
      unawaited(_handleSmartAction(tap));
      return;
    }
    // 正文点击：打开任务详情；来自提醒通知时详情页弹出「延后提醒」选择
    nav.push(
      MaterialPageRoute(
        builder: (_) => TaskDetailPage(
          taskId: info.taskId,
          fromNotification: info.reminderId != null ? tap : null,
        ),
      ),
    );
  }

  /// 智能提醒按钮 action 处理（贪睡/已完成）。前台分发与后台 isolate
  /// 共用 handleSmartReminderAction，保证行为一致；返回变更时刷新界面。
  Future<void> _handleSmartAction(NotificationTap tap) async {
    final db = ref.read(dbProvider);
    final scheduler = ref.read(reminderSchedulerProvider);
    final changed = await handleSmartReminderAction(
      db: db,
      scheduler: scheduler,
      actionId: tap.actionId,
      payload: tap.payload,
    );
    if (changed && mounted) {
      ref.read(dataVersionProvider.notifier).state++;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // C3：取消通知点击订阅，避免状态销毁后回调
    _tapSub?.cancel();
    super.dispose();
  }

  /// 回到前台：先刷新通知权限缓存，再按状态重排。
  /// HCI-1：用户在系统设置开启通知后返回 App（不重启/不进权限中心）时，
  /// 旧缓存 false 会让提醒全部静默跳过——先刷新缓存；若从"被拒"变"已授权"，
  /// 强制全量重排补齐之前被短路/清掉的提醒；否则走 24h 窗口滚动。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResume());
    }
  }

  Future<void> _onResume() async {
    final svc = ref.read(notificationServiceProvider);
    final wasDenied = svc.permissionCache == false;
    final granted = await svc.refreshPermissionCache();
    final scheduler = ref.read(reminderSchedulerProvider);
    if (wasDenied && granted) {
      await scheduler.rescheduleAll();
    } else {
      await scheduler.rescheduleIfStale();
    }
    // 后台智能提醒完成标记：App 被杀时点「已完成」，后台 isolate 写入 DB，
    // 回前台时消费标记并刷新界面（后台 isolate 无法直接通知主 isolate）
    final db = ref.read(dbProvider);
    final mark = await db.getSetting(settingsKeySmartReminderChanged);
    if (mark == '1') {
      await db.setSetting(settingsKeySmartReminderChanged, '');
      ref.read(dataVersionProvider.notifier).state++;
    }
  }

  Future<void> _restoreTab() async {
    final settings = ref.read(settingsProvider);
    final tab = await settings.getLastTab();
    // 用户已手动切换过 Tab（_tabChanged 标记）则丢弃恢复结果，
    // 避免慢查询返回后覆盖用户选择
    if (mounted && !_tabChanged && tab >= 0 && tab < 4) {
      setState(() => _tab = tab);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A1：懒加载——只创建到当前 Tab，已访问页缓存保留 State
    for (var i = 0; i <= _tab; i++) {
      _pages[i] ??= _buildPage(i);
    }
    return Scaffold(
      body: _TabTransition(
        tab: _tab,
        child: IndexedStack(
          index: _tab,
          children: [
            for (var i = 0; i < 4; i++) _pages[i] ?? const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _switchTo,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.checklist), label: '任务'),
          NavigationDestination(icon: Icon(Icons.calendar_month), label: '日历'),
          NavigationDestination(icon: Icon(Icons.grid_view), label: '四象限'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }
}

/// A1：Tab 切换动画层。
/// 关键：动画由本组件内部 controller 驱动（tab 变化时 forward(from:0)），
/// child（IndexedStack）不因 key 变化重建——彻底修复此前
/// `ValueKey('tab-switch-$_tab')` 导致 4 页全量重挂载的卡顿与状态丢失。
class _TabTransition extends StatefulWidget {
  const _TabTransition({required this.tab, required this.child});

  final int tab;
  final Widget child;

  @override
  State<_TabTransition> createState() => _TabTransitionState();
}

class _TabTransitionState extends State<_TabTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1.0, // 首帧不播动画
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _opacity = _curve;
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: const Offset(0.04, 0),
    end: Offset.zero,
  ).animate(_curve);

  @override
  void didUpdateWidget(_TabTransition old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}
