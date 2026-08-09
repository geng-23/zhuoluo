import 'dart:convert';

import 'package:zhuoluo/core/utils/app_clock.dart';
/// 日期工具（周一为一周开始，中文格式化）
///
/// 统一时间模型：所有取字段（year/month/day/hour/min）前先经
/// `AppClock.asApp()` 按应用时区解释——未设置应用时区时 asApp 原样返回，
/// 行为与之前完全一致；设置后字段按应用时区解释，避免跨时区偏移。
class DateUtilsEx {
  DateUtilsEx._();

  static const weekdayCn = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  /// 去掉时间部分（应用时区当天 00:00）
  static DateTime day(DateTime d) {
    final a = AppClock.asApp(d);
    return AppClock.at(a.year, a.month, a.day);
  }

  /// 周一的日期（按应用时区解释）
  static DateTime mondayOf(DateTime d) {
    final a = AppClock.asApp(d);
    final day = AppClock.at(a.year, a.month, a.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 是否为同一天（按应用时区解释比较）
  static bool sameDay(DateTime a, DateTime b) {
    final aa = AppClock.asApp(a);
    final bb = AppClock.asApp(b);
    return aa.year == bb.year && aa.month == bb.month && aa.day == bb.day;
  }

  /// 月份中文
  static String monthCn(DateTime d) {
    final a = AppClock.asApp(d);
    return '${a.year}年${a.month}月';
  }

  /// 日期中文："今天"/"明天"/"昨天"/"8月10日 周一"
  static String dateCn(DateTime d, {DateTime? now}) {
    final base = now ?? AppClock.now();
    final today = day(base);
    final target = day(d);
    if (sameDay(target, today)) return '今天';
    if (sameDay(target, today.add(const Duration(days: 1)))) return '明天';
    if (sameDay(target, today.subtract(const Duration(days: 1)))) return '昨天';
    if (target.year == today.year) {
      return '${target.month}月${target.day}日 ${weekdayCn[target.weekday - 1]}';
    }
    return '${target.year}年${target.month}月${target.day}日';
  }

  /// 时间中文："14:00"
  static String timeCn(DateTime t) {
    final a = AppClock.asApp(t);
    final hh = a.hour.toString().padLeft(2, '0');
    final mm = a.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// C5-1/落点"时长不跨天"约束——起点 + 时长越过当天 23:00 时
  /// 回退起点（23:00 - 时长），保证任务不跨午夜（跨天任务会跳进置顶区
  /// 且无法拖回）。写入端与拖拽预览端（虚影/时间胶囊）必须统一使用，
  /// 否则所见非所得（22:30 拖 2h 任务实际写入 21:00）。
  static DateTime clampStartWithinDay(DateTime start, Duration dur) {
    final a = AppClock.asApp(start);
    final endOfDay = AppClock.at(a.year, a.month, a.day, 23, 0);
    return start.add(dur).isAfter(endOfDay) ? endOfDay.subtract(dur) : start;
  }

  /// 某月第一天（按应用时区解释）
  static DateTime firstOfMonth(DateTime d) {
    final a = AppClock.asApp(d);
    return AppClock.at(a.year, a.month, 1);
  }

  /// 某月天数（按应用时区解释）
  static int daysInMonth(DateTime d) {
    final a = AppClock.asApp(d);
    return DateTime(a.year, a.month + 1, 0).day;
  }

  /// 重复任务实例日期统一归一化：当天 00:00（按应用时区解释）。
  /// 完成记录/提醒排期/跳过/例外必须共用同一基准，否则 RRULE 展开保留的时分
  /// （如 09:00）与完成记录（00:00）会互相判定为不同实例。
  static DateTime normalizeInstanceDate(DateTime d) {
    final a = AppClock.asApp(d);
    return AppClock.at(a.year, a.month, a.day);
  }

  /// skippedDates 非法 JSON（损坏备份导入等）静默视为无跳过，
  /// 避免跳过/撤销操作直接抛 FormatException。
  /// 任务页与日历页共用同一实现（此前日历侧漏掉容错直接 jsonDecode）。
  static List<String> parseSkippedDates(String raw) {
    if (raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => e as String).toList();
    } catch (_) {
      return [];
    }
  }
}
