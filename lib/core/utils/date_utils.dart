import 'package:zhuoluo/core/utils/app_clock.dart';
/// 日期工具（周一为一周开始，中文格式化）
class DateUtilsEx {
  DateUtilsEx._();

  static const weekdayCn = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  /// 去掉时间部分
  static DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 周一的日期
  static DateTime mondayOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 是否为同一天
  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 月份中文
  static String monthCn(DateTime d) => '${d.year}年${d.month}月';

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
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// C5-1/P1-7：落点"时长不跨天"约束——起点 + 时长越过当天 23:00 时
  /// 回退起点（23:00 - 时长），保证任务不跨午夜（跨天任务会跳进置顶区
  /// 且无法拖回）。写入端与拖拽预览端（虚影/时间胶囊）必须统一使用，
  /// 否则所见非所得（22:30 拖 2h 任务实际写入 21:00）。
  static DateTime clampStartWithinDay(DateTime start, Duration dur) {
    final endOfDay = DateTime(start.year, start.month, start.day, 23, 0);
    return start.add(dur).isAfter(endOfDay) ? endOfDay.subtract(dur) : start;
  }

  /// 某月第一天
  static DateTime firstOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

  /// 某月天数
  static int daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

  /// 过期判断（有计划日且早于今天且未完成）
  static bool isOverdue(DateTime? scheduledDate, {DateTime? now}) {
    if (scheduledDate == null) return false;
    final today = day(now ?? AppClock.now());
    return day(scheduledDate).isBefore(today);
  }

  /// 倒计时天数（正数=还有几天，负数=已过几天，0=今天）
  static int daysUntil(DateTime d, {DateTime? now}) {
    final today = day(now ?? AppClock.now());
    return day(d).difference(today).inDays;
  }

  /// 重复任务实例日期统一归一化：当天 00:00。
  /// 完成记录/提醒排期/跳过/例外必须共用同一基准，否则 RRULE 展开保留的时分
  /// （如 09:00）与完成记录（00:00）会互相判定为不同实例（P0-3.1）。
  static DateTime normalizeInstanceDate(DateTime d) => DateTime(
    d.year,
    d.month,
    d.day,
  );
}
