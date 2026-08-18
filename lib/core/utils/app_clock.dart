import 'package:flutter/foundation.dart' show visibleForTesting;
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
///
/// 日历日运算原则：**"下一天/日历日差/加 N 天"一律走本类提供的
/// [nextDay]/[addCalendarDays]/[daysBetween]/[weeksBetweenMonday]，禁止用
/// `add(Duration(days: 1))` 表示"次日 00:00"**——在 DST 时区，秋季回拨日
/// 00:00 + 24h = 同日 23:00，春季拨快日 00:00 + 24h = 次日 01:00，
/// 会破坏窗口边界/统计分组/重复实例判定。内部用应用时区取 y/m/d 后转
/// UTC 纯日期算术（DateTime.utc），彻底避开本地时长的 23h/25h 截断。
class AppClock {
  AppClock._();

  static String? _name;
  static tz.Location? _loc;
  static DateTime? _nowOverride;

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

  /// 测试时钟注入：固定 [now] 返回值（setUp 中设置，tearDown 传 null 复位）。
  /// 用于消除跨午夜/日期漂移导致的套件间口径不一致。
  @visibleForTesting
  static void setNow(DateTime? now) {
    _nowOverride = now;
  }

  /// 应用时区下的当前时刻（未设置时等同 DateTime.now()）；
  /// 测试注入后返回注入值（原样，不按应用时区重解释）。
  static DateTime now() {
    final o = _nowOverride;
    if (o != null) return o;
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

  // ---------- 日历日运算（DST 安全） ----------

  /// 应用时区当天 00:00（[asApp] 取字段后再归一）。
  static DateTime startOfDay(DateTime t) {
    final a = asApp(t);
    return at(a.year, a.month, a.day);
  }

  /// 应用时区"下一天"的 00:00。
  /// 不依赖 `add(Duration(days: 1))`：秋季回拨日 +24h 落在同日 23:00、
  /// 春季拨快日 +24h 落在次日 01:00，均非"次日 00:00"。
  static DateTime nextDay(DateTime t) {
    final a = asApp(t);
    return at(a.year, a.month, a.day + 1);
  }

  /// 应用时区日历日 +[n] 天，保留时分（[n] 可为负）。
  /// 用于"明天 15:00""3 天后 09:00"这类墙钟日期移动；
  /// 月/年溢出由 DateTime 归一化自动处理（如 13 月 → 次年 1 月）。
  static DateTime addCalendarDays(DateTime t, int n) {
    final a = asApp(t);
    return at(a.year, a.month, a.day + n, a.hour, a.minute);
  }

  /// 两个时刻在应用时区下的"日历日差"（b 相对 a，单位天，可为负）。
  /// 经 UTC 纯日期算术（DateTime.utc(y,m,d)），不受系统时区/DST 影响——
  /// 相邻两天在春季转换日差 23h，直接 `.difference().inDays` 会 floor 成 0。
  static int daysBetween(DateTime a, DateTime b) {
    final aa = asApp(a);
    final bb = asApp(b);
    final da = DateTime.utc(aa.year, aa.month, aa.day);
    final db = DateTime.utc(bb.year, bb.month, bb.day);
    return db.difference(da).inDays;
  }

  /// 以周一为基准的周数差（b 所在周相对 a 所在周，单位周，可为负）。
  /// 供 RRULE 周间隔与日历周视图页号使用；同样经 UTC 日期算术避开 DST。
  static int weeksBetweenMonday(DateTime a, DateTime b) {
    final aa = asApp(a);
    final bb = asApp(b);
    final da = DateTime.utc(aa.year, aa.month, aa.day);
    final db = DateTime.utc(bb.year, bb.month, bb.day);
    final ma = da.subtract(Duration(days: da.weekday - 1));
    final mb = db.subtract(Duration(days: db.weekday - 1));
    return mb.difference(ma).inDays ~/ 7;
  }
}
