import 'dart:async';

import 'package:zhuoluo/core/services/pomodoro_native.dart';

/// 记录型番茄钟原生桥替身：记录 start/update/stop 调用，
/// 并提供可控的动作事件流（simulateAction 注入原生→Dart 动作）。
///
/// 用法：
/// ```dart
/// final native = FakePomodoroNative();
/// container = ProviderContainer(overrides: [
///   dbProvider.overrideWithValue(db),
///   pomodoroNativeProvider.overrideWithValue(native),
/// ]);
/// ```
class FakePomodoroNative implements PomodoroNative {
  /// 前台服务启动记录（按调用顺序）
  final List<({int id, DateTime? endAt, bool running, int remainingSeconds})>
  starts = [];

  /// 通知更新记录（按调用顺序）
  final List<({int id, DateTime? endAt, bool running, int remainingSeconds})>
  updates = [];

  /// 停止服务记录（通知 ID）
  final List<int> stops = [];

  /// init() 调用次数
  int initCount = 0;

  final _actions = StreamController<String>.broadcast();

  @override
  Stream<String> get actions => _actions.stream;

  @override
  void init() {
    initCount++;
  }

  @override
  Future<void> startForeground({
    required int id,
    DateTime? endAt,
    required bool running,
    required int remainingSeconds,
  }) async {
    starts.add((
      id: id,
      endAt: endAt,
      running: running,
      remainingSeconds: remainingSeconds,
    ));
  }

  @override
  Future<void> updateForeground({
    required int id,
    DateTime? endAt,
    required bool running,
    required int remainingSeconds,
  }) async {
    updates.add((
      id: id,
      endAt: endAt,
      running: running,
      remainingSeconds: remainingSeconds,
    ));
  }

  @override
  Future<void> stopForeground({required int id}) async {
    stops.add(id);
  }

  /// 模拟一次通知动作点击（注入原生→Dart 动作事件）
  void simulateAction(String actionId) {
    _actions.add(actionId);
  }

  void clear() {
    starts.clear();
    updates.clear();
    stops.clear();
  }
}
