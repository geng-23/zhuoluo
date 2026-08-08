import 'package:flutter/foundation.dart';

/// native 平台：无浏览器通知，全部空实现
class WebNotificationBridge {
  WebNotificationBridge._();

  static final WebNotificationBridge instance = WebNotificationBridge._();

  Future<bool> requestPermission() async => true;

  bool get permissionGranted => true;

  void scheduleWeb(
    int id, {
    required String title,
    required String body,
    required DateTime when,
    required String payload,
    VoidCallback? onClick,
  }) {}

  void scheduleDailyWeb(
    int id, {
    required String title,
    required String body,
    required DateTime time,
    required String payload,
    VoidCallback? onClick,
  }) {}

  void cancel(int id) {}

  void cancelAll() {}
}
