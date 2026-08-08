import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Web 浏览器通知桥：
/// - 页面存活期间用内存 Timer 在到点时弹浏览器通知
/// - 页面刷新后由启动时的 rescheduleAll 重新建立 Timer
/// - 页面关闭后浏览器无法后台定时（平台限制）
class WebNotificationBridge {
  WebNotificationBridge._();

  static final WebNotificationBridge instance = WebNotificationBridge._();

  final Map<int, Timer> _timers = {};

  /// 请求浏览器通知权限（用户会看到授权弹窗）
  Future<bool> requestPermission() async {
    try {
      final p = await web.Notification.requestPermission().toDart;
      return p == 'granted';
    } catch (_) {
      return false;
    }
  }

  bool get permissionGranted => web.Notification.permission == 'granted';

  /// 到点弹一次通知
  void scheduleWeb(
    int id, {
    required String title,
    required String body,
    required DateTime when,
    required String payload,
    VoidCallback? onClick,
  }) {
    _timers.remove(id)?.cancel();
    final delay = when.difference(DateTime.now());
    if (delay.isNegative) return;
    _timers[id] = Timer(delay, () {
      _timers.remove(id);
      _show(id, title, body, onClick);
    });
  }

  /// 每日固定时刻重复（页面存活期间每日触发）
  void scheduleDailyWeb(
    int id, {
    required String title,
    required String body,
    required DateTime time,
    required String payload,
    VoidCallback? onClick,
  }) {
    void scheduleNext() {
      var next = time;
      final now = DateTime.now();
      while (!next.isAfter(now)) {
        next = next.add(const Duration(days: 1));
      }
      _timers.remove(id)?.cancel();
      _timers[id] = Timer(next.difference(now), () {
        _show(id, title, body, onClick);
        scheduleNext();
      });
    }

    scheduleNext();
  }

  void _show(int id, String title, String body, VoidCallback? onClick) {
    if (web.Notification.permission != 'granted') return;
    final n = web.Notification(
      title,
      web.NotificationOptions(body: body, tag: '$id'),
    );
    if (onClick != null) {
      n.onclick = (web.Event _) {
        onClick();
      }.toJS;
    }
  }

  void cancel(int id) {
    _timers.remove(id)?.cancel();
  }

  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}
