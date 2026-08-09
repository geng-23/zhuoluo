
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 时间轴基础参数
const startHour = 6;
const endHour = 23;
const pixelPerHour = 64.0;

/// 按天索引 key（与 CalendarController 的 byDay 同口径； 统一按应用时区）
int dayKey(DateTime d) {
  final a = AppClock.asApp(d);
  return a.year * 10000 + a.month * 100 + a.day;
}
