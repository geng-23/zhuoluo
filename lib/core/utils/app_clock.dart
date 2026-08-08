import 'package:timezone/timezone.dart' as tz;

/// 应用时区时钟（偏好设置组：出差/旅行保持家乡时间）。
///
/// 设置了应用时区后，全库统一经 [now] 取"当前时刻"——绝对时刻与
/// DateTime.now() 相同（isBefore/difference 等比较不受影响），但
/// year/month/day/hour 等字段按应用时区解释，显示与提醒均按家乡时间。
/// 未设置时行为与 DateTime.now() 完全一致（跟随系统时区）。
///
/// 前置条件：使用前需初始化时区数据（main.dart 中 notificationService.init()
/// 已调用 tzdata.initializeTimeZones()）。
class AppClock {
  AppClock._();

  static String? _name;
  static tz.Location? _loc;

  /// 设置应用时区（IANA 名称）。null/空 = 跟随系统时区；非法名称回落系统。
  static void setTimezone(String? ianaName) {
    if (ianaName == null || ianaName.isEmpty) {
      _name = null;
      _loc = null;
      return;
    }
    try {
      _loc = tz.getLocation(ianaName);
      _name = ianaName;
    } catch (_) {
      // 非法/未初始化的时区名：回退系统时区，不抛异常
      _name = null;
      _loc = null;
    }
  }

  /// 应用时区 IANA 名称；null = 跟随系统时区
  static String? get timezoneName => _name;

  /// 应用时区下的当前时刻（未设置时等同 DateTime.now()）
  static DateTime now() {
    final loc = _loc;
    if (loc == null) return DateTime.now();
    return tz.TZDateTime.now(loc);
  }

  /// 通知排期/换算用位置（未设置时跟随系统 tz.local）
  static tz.Location get location => _loc ?? tz.local;
}
