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
  final List<({int id, bool running, int remainingSeconds, int totalSeconds, String? title})>
  starts = [];

  /// 通知更新记录（按调用顺序）
  final List<({int id, bool running, int remainingSeconds, int totalSeconds, String? title})>
  updates = [];

  /// 停止服务记录（通知 ID）
  final List<int> stops = [];

  /// init() 调用次数
  int initCount = 0;

  final _actions = StreamController<String>.broadcast();
  final _opens = StreamController<void>.broadcast();

  @override
  Stream<String> get actions => _actions.stream;

  @override
  Stream<void> get opens => _opens.stream;

  bool _pendingOpen = false;
  bool _foregroundActive = false;

  @override
  bool consumePendingOpen() {
    final pending = _pendingOpen;
    _pendingOpen = false;
    return pending;
  }

  @override
  bool get foregroundActive => _foregroundActive;

  @override
  void init() {
    initCount++;
  }

  @override
  Future<void> startForeground({
    required int id,
    required bool running,
    required int remainingSeconds,
    required int totalSeconds,
    String? title,
  }) async {
    _foregroundActive = true;
    starts.add((
      id: id,
      running: running,
      remainingSeconds: remainingSeconds,
      totalSeconds: totalSeconds,
      title: title,
    ));
  }

  @override
  Future<void> updateForeground({
    required int id,
    required bool running,
    required int remainingSeconds,
    required int totalSeconds,
    String? title,
  }) async {
    updates.add((
      id: id,
      running: running,
      remainingSeconds: remainingSeconds,
      totalSeconds: totalSeconds,
      title: title,
    ));
  }

  @override
  Future<void> stopForeground({required int id}) async {
    _foregroundActive = false;
    stops.add(id);
  }

  /// 模拟一次通知动作点击（注入原生→Dart 动作事件）
  void simulateAction(String actionId) {
    _actions.add(actionId);
  }

  /// 模拟一次通知主体点击（注入原生→Dart 打开事件；置 latch + 发流，
  /// 与真实桥行为一致）
  void emitOpen() {
    _pendingOpen = true;
    _opens.add(null);
  }

  /// 模拟冷启动竞态：openPomodoro 先于 HomeShell 订阅到达——只置 latch，
  /// 不发流（broadcast 流无监听时事件本就被丢弃）
  void emitOpenBeforeSubscribe() {
    _pendingOpen = true;
  }

  void clear() {
    starts.clear();
    updates.clear();
    stops.clear();
  }
}
