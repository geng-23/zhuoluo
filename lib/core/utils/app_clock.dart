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

  /// 应用时区下的"墙上时间"构造（统一时间模型）。
  /// 未设置应用时区时退化为普通 DateTime(y,m,d,h,min)，行为完全不变；
  /// 设置了应用时区时返回该时区的 TZDateTime（绝对时刻 = 应用时区墙上时间）。
  /// 业务写入侧构造任务时间/提醒基准/日历窗口必须走本方法，
  /// 避免普通 DateTime 按系统时区解释造成跨时区偏移。
  static DateTime at(
    int y,
    int m,
    int d, [
    int h = 0,
    int min = 0,
  ]) {
    final loc = _loc;
    if (loc == null) return DateTime(y, m, d, h, min);
    return tz.TZDateTime(loc, y, m, d, h, min);
  }

  /// 把任意 DateTime 按应用时区重新解释（统一时间模型）。
  /// 未设置应用时区时原样返回；设置了应用时区时返回 TZDateTime——
  /// 绝对时刻不变，仅字段（year/month/day/hour 等）改按应用时区解释。
  /// 业务读取侧从数据库取出的时间必须先经本方法再取字段，
  /// 否则字段按系统时区解释造成跨时区偏移。
  static DateTime asApp(DateTime t) {
    final loc = _loc;
    if (loc == null) return t;
    return tz.TZDateTime.from(t, loc);
  }

  /// 通知排期/换算用位置（未设置时跟随系统 tz.local）
  static tz.Location get location => _loc ?? tz.local;
}
