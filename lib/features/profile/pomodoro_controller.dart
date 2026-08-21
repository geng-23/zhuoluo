import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/pomodoro_native.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/services/notification_service.dart';

/// 番茄钟状态：未开始 / 计时中 / 已暂停
enum PomodoroState { idle, running, paused }

/// 番茄钟运行状态快照（页面展示 + 通知同步的数据源）
@immutable
class PomodoroStatus {
  const PomodoroStatus({
    required this.state,
    required this.minutes,
    required this.remainingSeconds,
    required this.taskId,
  });

  factory PomodoroStatus.initial() => const PomodoroStatus(
    state: PomodoroState.idle,
    minutes: 25,
    remainingSeconds: 25 * 60,
    taskId: null,
  );

  final PomodoroState state;

  /// 会话总时长（分钟）
  final int minutes;

  /// 剩余秒数
  final int remainingSeconds;

  /// 关联任务 id（null = 不关联）
  final int? taskId;
}

/// 专注结束结果（页面据其弹提示）
class PomodoroFinishResult {
  const PomodoroFinishResult({required this.minutes, this.error});

  /// 实际专注分钟（0 = 立即结束）
  final int minutes;

  /// 记录保存失败信息（null = 成功）
  final String? error;

  bool get isSuccess => error == null;
}

/// 番茄钟进程级控制器。
///
/// 状态提升到 App 级（[pomodoroControllerProvider] 非 autoDispose），
/// 页面销毁/返回不影响计时——仅当用户点击暂停/停止或进程被杀才终止；
/// 计时期间通知栏常驻倒计时与控制按钮（暂停/继续/结束）。
///
/// 时间模型：运行态记录目标结束时刻 [_endAt]，每秒 tick 用墙钟重算剩余，
/// 挂起/Doze 导致 tick 延迟时自动纠偏，通知栏倒计时保持准确。
class PomodoroController extends StateNotifier<PomodoroStatus> {
  PomodoroController(this._ref) : super(PomodoroStatus.initial()) {
    // 注册原生→Dart 动作通道（幂等），并订阅通知动作（暂停/继续/结束）。
    // 通知只存在于计时会话期间，而会话只能由页面发起（打开页面必然先创建
    // 本控制器），订阅必然已生效。
    final native = _ref.read(pomodoroNativeProvider);
    native.init();
    _actionSub = native.actions.listen(_onNotificationAction);
  }

  /// 通知动作 ID（与原生 PomodoroActionReceiver 口径一致）
  static const actionPause = 'pause';
  static const actionResume = 'resume';
  static const actionStop = 'stop';

  final Ref _ref;
  Timer? _timer;

  /// 运行态目标结束时刻（墙钟）；非 running 时为 null
  DateTime? _endAt;

  /// 当前连续运行段的起始时刻（running 时有效）
  DateTime? _startedAt;

  /// 已累计专注秒数（不含暂停时段；finish 时据其算实际时长，
  /// 与"每秒递减"等价但不受 tick 延迟/挂起影响）
  int _elapsedSec = 0;

  /// 暂停时冻结的剩余秒数
  int _pausedRemaining = 0;

  /// 关联任务标题（通知展示用；页面开始/重新开始时传入）
  String? _taskTitle;

  StreamSubscription<String>? _actionSub;
  final _finished = StreamController<PomodoroFinishResult>.broadcast();

  /// 专注结束事件流（成功/失败均发；页面 mounted 时据其弹提示）
  Stream<PomodoroFinishResult> get finished => _finished.stream;

  @override
  void dispose() {
    _timer?.cancel();
    _actionSub?.cancel();
    _finished.close();
    super.dispose();
  }

  /// 开始计时（仅空闲态有效）。[taskTitle] 关联任务标题（通知展示用）。
  void start({String? taskTitle}) {
    if (state.state != PomodoroState.idle) return;
    final minutes = state.minutes;
    _elapsedSec = 0;
    _startedAt = AppClock.now();
    _endAt = _startedAt!.add(Duration(minutes: minutes));
    _taskTitle = taskTitle;
    state = PomodoroStatus(
      state: PomodoroState.running,
      minutes: minutes,
      remainingSeconds: minutes * 60,
      taskId: state.taskId,
    );
    SoundService.instance.play(SoundKind.add);
    // 清除上一会话残留通知（完成提醒等），再启动前台服务显示倒计时
    unawaited(_ref.read(notificationServiceProvider).cancelPomodoro());
    unawaited(
      _native().startForeground(
        id: NotificationIds.forPomodoro,
        running: true,
        remainingSeconds: minutes * 60,
        totalSeconds: minutes * 60,
        title: _taskTitle,
      ),
    );
    _startTicker();
  }

  PomodoroNative _native() => _ref.read(pomodoroNativeProvider);

  /// 把当前运行段秒数并入 [_elapsedSec] 并清零 [_startedAt]（暂停/结束时调用）
  void _accumulateElapsed() {
    final s = _startedAt;
    if (s != null) {
      _elapsedSec += AppClock.now().difference(s).inSeconds;
      _startedAt = null;
    }
  }

  void _startTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 每秒 tick：墙钟重算剩余；归零结束；否则刷新状态并每秒推送
  /// 通知正文实时倒计时（chronometer 部分 ROM 不渲染，文本更新全设备一致）。
  void _tick() {
    if (state.state != PomodoroState.running) return;
    final endAt = _endAt;
    if (endAt == null) return;
    final remaining = endAt.difference(AppClock.now()).inSeconds;
    if (remaining <= 0) {
      unawaited(finish());
      return;
    }
    state = PomodoroStatus(
      state: state.state,
      minutes: state.minutes,
      remainingSeconds: remaining,
      taskId: state.taskId,
    );
    // 每秒推送剩余秒数：通知正文实时倒计时（部分 ROM 不渲染 chronometer，
    // 文本更新全设备一致；onlyAlertOnce 保证不响铃）
    unawaited(
      _native().updateForeground(
        id: NotificationIds.forPomodoro,
        running: true,
        remainingSeconds: remaining,
        totalSeconds: state.minutes * 60,
        title: _taskTitle,
      ),
    );
  }

  /// 暂停（仅运行态有效）
  void pause() {
    if (state.state != PomodoroState.running) return;
    _timer?.cancel();
    _accumulateElapsed();
    _endAt = null; // 暂停后 tick 不得再推进（结束时刻失效）
    _pausedRemaining = state.remainingSeconds;
    state = PomodoroStatus(
      state: PomodoroState.paused,
      minutes: state.minutes,
      remainingSeconds: state.remainingSeconds,
      taskId: state.taskId,
    );
    SoundService.instance.play(SoundKind.pomodoroPause);
    unawaited(
      _native().updateForeground(
        id: NotificationIds.forPomodoro,
        running: false,
        remainingSeconds: _pausedRemaining,
        totalSeconds: state.minutes * 60,
        title: _taskTitle,
      ),
    );
  }

  /// 继续（仅暂停态有效）
  void resume() {
    if (state.state != PomodoroState.paused) return;
    _startedAt = AppClock.now();
    _endAt = _startedAt!.add(Duration(seconds: _pausedRemaining));
    state = PomodoroStatus(
      state: PomodoroState.running,
      minutes: state.minutes,
      remainingSeconds: _pausedRemaining,
      taskId: state.taskId,
    );
    SoundService.instance.play(SoundKind.pomodoroResume);
    unawaited(
      _native().updateForeground(
        id: NotificationIds.forPomodoro,
        running: true,
        remainingSeconds: _pausedRemaining,
        totalSeconds: state.minutes * 60,
        title: _taskTitle,
      ),
    );
    _startTicker();
  }

  /// 重新开始：放弃当前进度，从头计时（运行/暂停态有效）。
  /// [taskTitle] 关联任务标题（通知展示用）。
  void restart({String? taskTitle}) {
    if (state.state == PomodoroState.idle) return;
    final minutes = state.minutes;
    _elapsedSec = 0;
    _startedAt = AppClock.now();
    _endAt = _startedAt!.add(Duration(minutes: minutes));
    _taskTitle = taskTitle;
    state = PomodoroStatus(
      state: PomodoroState.running,
      minutes: minutes,
      remainingSeconds: minutes * 60,
      taskId: state.taskId,
    );
    SoundService.instance.play(SoundKind.add);
    unawaited(
      _native().startForeground(
        id: NotificationIds.forPomodoro,
        running: true,
        remainingSeconds: minutes * 60,
        totalSeconds: minutes * 60,
        title: _taskTitle,
      ),
    );
    _startTicker();
  }

  /// 结束（含提前结束/归零）：记录实际专注时长，清理通知。
  /// 前台完成走应用内反馈（音效+页面提示）；后台完成弹完成通知。
  Future<void> finish() async {
    _timer?.cancel();
    _endAt = null;
    _accumulateElapsed();
    // 立即结束（elapsedSec <= 0）记录 0 分钟
    // （此前会把完整 15/25/45 分钟记进统计）
    final elapsedMin = _elapsedSec <= 0
        ? 0
        : (_elapsedSec / 60).ceil().clamp(1, state.minutes);
    final taskId = state.taskId;
    final minutes = state.minutes;
    // 恢复待开始显示时长（而非 00:00）
    state = PomodoroStatus(
      state: PomodoroState.idle,
      minutes: minutes,
      remainingSeconds: minutes * 60,
      taskId: taskId,
    );
    // 停止前台服务（移除倒计时通知、结束进程保活），再弹完成提醒
    unawaited(_native().stopForeground(id: NotificationIds.forPomodoro));
    final notifications = _ref.read(notificationServiceProvider);
    await notifications.cancelPomodoro();
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      // 完成通知尽力而为：失败不影响记录写入与反馈
      unawaited(
        notifications.showPomodoroFinished(minutes: elapsedMin).catchError(
          (Object e) => debugPrint('番茄钟完成通知失败: $e'),
        ),
      );
    }
    // 数据库保存成功后再反馈；捕获外键异常（关联任务被删除时
    // insertPomodoro 抛错，此前无反馈）
    try {
      await _ref.read(dbProvider).insertPomodoro(
        taskId,
        elapsedMin,
        AppClock.now().subtract(Duration(minutes: elapsedMin)),
      );
      // 番茄记录写库后通知统计等依赖方
      _ref.read(dataVersionProvider.notifier).state++;
    } catch (e) {
      debugPrint('番茄记录保存失败: $e');
      _finished.add(
        PomodoroFinishResult(
          minutes: elapsedMin,
          error: taskId != null ? '关联任务可能已删除' : '$e',
        ),
      );
      return;
    }
    SoundService.instance.play(SoundKind.complete);
    Haptics.medium();
    _finished.add(PomodoroFinishResult(minutes: elapsedMin));
  }

  /// 设置会话时长（仅空闲态有效）
  void setMinutes(int m) {
    if (state.state != PomodoroState.idle) return;
    state = PomodoroStatus(
      state: state.state,
      minutes: m,
      remainingSeconds: m * 60,
      taskId: state.taskId,
    );
  }

  /// 设置关联任务（仅空闲态有效）
  void setTaskId(int? id) {
    if (state.state != PomodoroState.idle) return;
    state = PomodoroStatus(
      state: state.state,
      minutes: state.minutes,
      remainingSeconds: state.remainingSeconds,
      taskId: id,
    );
  }

  /// 通知栏动作分发（暂停/继续/结束）
  void _onNotificationAction(String actionId) {
    switch (actionId) {
      case actionPause:
        pause();
      case actionResume:
        resume();
      case actionStop:
        unawaited(finish());
      default:
        break;
    }
  }

  /// 测试用：同步执行一次 tick（配合 AppClock.setNow 注入推进时间，
  /// 规避真实 Timer 的不确定性）。
  @visibleForTesting
  void debugTick() => _tick();
}

/// 番茄钟控制器（进程级：非 autoDispose，页面销毁不影响计时）
final pomodoroControllerProvider =
    StateNotifierProvider<PomodoroController, PomodoroStatus>(
      (ref) => PomodoroController(ref),
    );
