import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 番茄钟原生前台服务桥（生产 = MethodChannel 到 [PomodoroService]；
/// 测试 = override provider 注入记录型替身）。
///
/// 职责：会话期间保持进程存活 + 托管常驻倒计时通知。倒计时由 Dart 每秒
/// 推送剩余秒数、原生正文实时显示（chronometer 部分 ROM 不渲染，故文本
/// 每秒更新，全设备一致）；通知动作（暂停/继续/结束）由原生接收器经
/// [actions] 流送回 Dart 主隔离区；点击通知主体经 [opens] 流通知
/// HomeShell 导航到番茄专注页。
///
/// 所有方法尽力而为：平台不可用（测试环境/通道异常）时静默降级，
/// 绝不影响计时与记录。
class PomodoroNative {
  PomodoroNative._();

  static final PomodoroNative instance = PomodoroNative._();

  static const MethodChannel _channel = MethodChannel('zhuoluo/pomodoro');

  /// 通知动作事件流（pause / resume / stop；原生 ActionReceiver 转发而来）
  final _actions = StreamController<String>.broadcast();
  Stream<String> get actions => _actions.stream;

  /// 通知主体点击事件流（原生 contentIntent 转发而来；HomeShell 订阅后
  /// 导航到番茄专注页）
  final _opens = StreamController<void>.broadcast();
  Stream<void> get opens => _opens.stream;

  bool _handlerSet = false;

  /// 注册原生→Dart 通道（幂等；main 启动时调用，保证冷启动即就绪）。
  void init() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'action':
          final actionId = call.arguments;
          if (actionId is String && actionId.isNotEmpty) {
            _actions.add(actionId);
          }
        case 'openPomodoro':
          _opens.add(null);
        default:
          break;
      }
    });
  }

  /// 启动前台服务并发布常驻倒计时通知。
  /// [title] 关联任务标题（无则 null，原生标题显示"番茄专注"）。
  Future<void> startForeground({
    required int id,
    required bool running,
    required int remainingSeconds,
    required int totalSeconds,
    String? title,
  }) {
    return _invoke(
      'startForeground',
      _args(running, remainingSeconds, totalSeconds, title, id: id),
    );
  }

  /// 更新通知内容（不改变前台状态；Dart 每秒推送实时倒计时）。
  Future<void> updateForeground({
    required int id,
    required bool running,
    required int remainingSeconds,
    required int totalSeconds,
    String? title,
  }) {
    return _invoke(
      'updateForeground',
      _args(running, remainingSeconds, totalSeconds, title, id: id),
    );
  }

  /// 停止服务并移除通知（会话结束）。
  Future<void> stopForeground({required int id}) {
    return _invoke('stopForeground', {'id': id});
  }

  Map<String, Object?> _args(
    bool running,
    int remainingSeconds,
    int totalSeconds,
    String? title, {
    required int id,
  }) =>
      {
        'id': id,
        'running': running,
        'remainingSec': remainingSeconds,
        'totalSec': totalSeconds,
        'title': title,
      };

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      // 平台不可用（测试环境/通道异常）：静默降级，计时不受影响
      debugPrint('番茄钟原生桥 $method 调用失败: $e');
    }
  }
}

/// 番茄钟原生桥（单例；测试 override 注入 FakePomodoroNative）
final pomodoroNativeProvider = Provider<PomodoroNative>(
  (ref) => PomodoroNative.instance,
);
