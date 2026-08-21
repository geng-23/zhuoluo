import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 番茄钟原生前台服务桥（生产 = MethodChannel 到 [PomodoroService]；
/// 测试 = override provider 注入记录型替身）。
///
/// 职责：会话期间保持进程存活 + 托管常驻倒计时通知。通知读秒由系统
/// chronometer 按结束时刻原生渲染（进程冻结也精确）；通知动作（暂停/继续/结束）
/// 由原生接收器经本桥的 [actions] 流送回 Dart 主隔离区。
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

  bool _handlerSet = false;

  /// 注册原生→Dart 动作通道（幂等；由 PomodoroController 构造时调用，
  /// 会话只能从页面发起，注册必然先于任何通知存在）。
  void init() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action') {
        final actionId = call.arguments;
        if (actionId is String && actionId.isNotEmpty) {
          _actions.add(actionId);
        }
      }
    });
  }

  /// 启动前台服务并发布常驻倒计时通知。
  /// [endAt] 运行态的结束时刻（chronometer 按此渲染倒计时）；暂停态传 null。
  Future<void> startForeground({
    required int id,
    DateTime? endAt,
    required bool running,
    required int remainingSeconds,
  }) {
    return _invoke('startForeground', _args(endAt, running, remainingSeconds, id: id));
  }

  /// 更新通知内容（不改变前台状态；运行态每 10s 自愈重发）。
  Future<void> updateForeground({
    required int id,
    DateTime? endAt,
    required bool running,
    required int remainingSeconds,
  }) {
    return _invoke('updateForeground', _args(endAt, running, remainingSeconds, id: id));
  }

  /// 停止服务并移除通知（会话结束）。
  Future<void> stopForeground({required int id}) {
    return _invoke('stopForeground', {'id': id});
  }

  Map<String, Object?> _args(
    DateTime? endAt,
    bool running,
    int remainingSeconds, {
    required int id,
  }) =>
      {
        'id': id,
        'endAtMs': endAt?.millisecondsSinceEpoch,
        'running': running,
        'remainingSec': remainingSeconds,
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
