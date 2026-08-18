import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 日历日运算基础单元测试：
/// - nextDay / addCalendarDays / daysBetween / weeksBetweenMonday 在
///   DST 时区（America/New_York）转换日必须给出"日历日"语义，
///   不得受 23h/25h 时长截断影响
/// - setNow 测试时钟注入复位
/// - 无 DST 时区（Asia/Shanghai）行为与 Duration 加法一致（不回归）
void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  tearDown(() {
    AppClock.setTimezone(null);
    AppClock.setNow(null);
    AppClock.syncSystemTimezone(null);
  });

  group('nextDay', () {
    test('秋季回拨日（2026-11-01）：返回 11-02 00:00 而非 11-01 23:00', () {
      AppClock.setTimezone('America/New_York');
      // 2026-11-01 02:00 EDT → 01:00 EST（回拨 1 小时）
      final day = AppClock.at(2026, 11, 1);
      final next = AppClock.nextDay(day);
      final a = AppClock.asApp(next);
      expect(a.year, 2026);
      expect(a.month, 11);
      expect(a.day, 2);
      expect(a.hour, 0);
      expect(a.minute, 0);
      // 旧写法 add(Duration(days:1)) 在秋季转换日给出 11-01 23:00
      expect(
        AppClock.asApp(day.add(const Duration(days: 1))).day,
        1,
        reason: '对照：+24h 落在同日 23:00，证明必须用 nextDay',
      );
    });

    test('春季拨快日（2026-03-08）：返回 03-09 00:00', () {
      AppClock.setTimezone('America/New_York');
      final day = AppClock.at(2026, 3, 8);
      final next = AppClock.nextDay(day);
      final a = AppClock.asApp(next);
      expect(a.year, 2026);
      expect(a.month, 3);
      expect(a.day, 9);
      expect(a.hour, 0);
    });

    test('跨月/跨年溢出自动归一化', () {
      AppClock.setTimezone('America/New_York');
      final next = AppClock.nextDay(AppClock.at(2026, 12, 31));
      final a = AppClock.asApp(next);
      expect(a.year, 2027);
      expect(a.month, 1);
      expect(a.day, 1);
    });

    test('无 DST 时区（Asia/Shanghai）行为与 +24h 一致', () {
      AppClock.setTimezone('Asia/Shanghai');
      final day = AppClock.at(2026, 11, 1);
      final next = AppClock.nextDay(day);
      expect(
        next.millisecondsSinceEpoch,
        day.add(const Duration(days: 1)).millisecondsSinceEpoch,
      );
    });
  });

  group('addCalendarDays', () {
    test('保留时分跨 DST 转换日', () {
      AppClock.setTimezone('America/New_York');
      // 秋季回拨日当天 09:30 +1 天 = 次日 09:30
      final t = AppClock.at(2026, 11, 1, 9, 30);
      final next = AppClock.addCalendarDays(t, 1);
      final a = AppClock.asApp(next);
      expect(a.month, 11);
      expect(a.day, 2);
      expect(a.hour, 9);
      expect(a.minute, 30);
    });

    test('负数天数（昨天）', () {
      AppClock.setTimezone('America/New_York');
      final t = AppClock.at(2026, 11, 1, 9, 30);
      final prev = AppClock.addCalendarDays(t, -1);
      final a = AppClock.asApp(prev);
      expect(a.month, 10);
      expect(a.day, 31);
      expect(a.hour, 9);
      expect(a.minute, 30);
    });

    test('跨 8 周（7 天×8）不随时间累积漂移', () {
      AppClock.setTimezone('America/New_York');
      // 2026-03-08 春季转换日落在 8 周窗口内
      final start = AppClock.at(2026, 2, 1, 6, 0);
      final end = AppClock.addCalendarDays(start, 56);
      final a = AppClock.asApp(end);
      expect(a.month, 3);
      expect(a.day, 29);
      expect(a.hour, 6);
    });
  });

  group('daysBetween', () {
    test('春季转换日相邻两天差 1（对照 inDays 得 0）', () {
      AppClock.setTimezone('America/New_York');
      final d1 = AppClock.at(2026, 3, 8);
      final d2 = AppClock.at(2026, 3, 9);
      expect(AppClock.daysBetween(d1, d2), 1);
      // 对照：绝对时长差 23h → floor 成 0
      expect(d2.difference(d1).inDays, 0,
          reason: '证明直接 inDays 在 DST 下不可用');
    });

    test('秋季转换日相邻两天差 1（对照 inDays 得 1，但次日为 23h 也不该跳号）', () {
      AppClock.setTimezone('America/New_York');
      final d1 = AppClock.at(2026, 11, 1);
      final d2 = AppClock.at(2026, 11, 2);
      expect(AppClock.daysBetween(d1, d2), 1);
    });

    test('带时分输入按日历日对齐（23:59 仍属当天）', () {
      AppClock.setTimezone('America/New_York');
      final d1 = AppClock.at(2026, 8, 10, 0, 0);
      final d2 = AppClock.at(2026, 8, 10, 23, 59);
      expect(AppClock.daysBetween(d1, d2), 0);
      expect(AppClock.daysBetween(d2, AppClock.at(2026, 8, 11, 0, 1)), 1);
    });

    test('负方向（b 早于 a）', () {
      AppClock.setTimezone('America/New_York');
      expect(AppClock.daysBetween(AppClock.at(2026, 8, 11), AppClock.at(2026, 8, 10)), -1);
    });

    test('应用时区 ≠ 系统时区：跨时区输入仍按应用时区日历日', () {
      AppClock.setTimezone('America/New_York');
      // 传入 UTC 时刻：UTC 8/11 05:00 = 纽约 8/11 01:00
      final a = DateTime.utc(2026, 8, 10, 5, 0); // 纽约 8/10 01:00
      final b = DateTime.utc(2026, 8, 11, 5, 0); // 纽约 8/11 01:00
      expect(AppClock.daysBetween(a, b), 1);
    });
  });

  group('weeksBetweenMonday', () {
    test('跨春季转换日的相邻两周差 1', () {
      AppClock.setTimezone('America/New_York');
      // 2026-03-02 是周一；2026-03-08 周日；2026-03-09 周一（转换日次日）
      final w1 = AppClock.at(2026, 3, 2); // 周一
      final w2 = AppClock.at(2026, 3, 9); // 周一
      expect(AppClock.weeksBetweenMonday(w1, w2), 1);
    });

    test('同周内不同天差 0', () {
      AppClock.setTimezone('America/New_York');
      final monday = AppClock.at(2026, 3, 2);
      final sunday = AppClock.at(2026, 3, 8);
      expect(AppClock.weeksBetweenMonday(monday, sunday), 0);
    });

    test('跨多周（含转换日）', () {
      AppClock.setTimezone('America/New_York');
      final w1 = AppClock.at(2026, 2, 23); // 周一
      final w5 = AppClock.at(2026, 3, 23); // 周一（中间含 3/8 春季转换）
      expect(AppClock.weeksBetweenMonday(w1, w5), 4);
    });
  });

  group('syncSystemTimezone（跟随系统时区，运行中变化可切换）', () {
    test('未设应用时区时按显式系统时区构造/解释', () {
      AppClock.syncSystemTimezone('America/New_York');
      // 纽约 EDT（UTC-4）09:00 = 13:00Z
      final t = AppClock.at(2026, 8, 18, 9, 0);
      expect(
        t.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 18, 13, 0).millisecondsSinceEpoch,
      );
      expect(AppClock.asApp(t).hour, 9);
      expect(AppClock.systemTimezoneName, 'America/New_York');
    });

    test('运行中切换系统时区：同一墙钟时间的绝对时刻即时变化', () {
      AppClock.syncSystemTimezone('America/New_York');
      final ny = AppClock.at(2026, 8, 18, 9, 0);
      // 模拟改系统时区：回前台重新同步
      AppClock.syncSystemTimezone('America/Los_Angeles');
      final la = AppClock.at(2026, 8, 18, 9, 0);
      expect(
        la.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 18, 16, 0).millisecondsSinceEpoch,
        reason: 'LA PDT(UTC-7) 09:00 = 16:00Z，与纽约 13:00Z 不同',
      );
      expect(ny.millisecondsSinceEpoch, isNot(la.millisecondsSinceEpoch));
      // 已构造的绝对时刻按新时区解释字段随之变化：13:00Z 在 LA = 06:00
      expect(AppClock.asApp(ny).hour, 6,
          reason: '纽约 09:00 = 13:00Z，切到 LA 后同一时刻字段变 06:00');
    });

    test('同步 null/非法名回退引擎本地时区（行为不变）', () {
      AppClock.syncSystemTimezone(null);
      expect(AppClock.systemTimezoneName, isNull);
      final t = AppClock.at(2026, 8, 18, 9, 0);
      expect(
        t.millisecondsSinceEpoch,
        DateTime(2026, 8, 18, 9, 0).millisecondsSinceEpoch,
        reason: '未启用显式时区时退化为普通 DateTime（系统 TZ 环境）',
      );
      AppClock.syncSystemTimezone('Not/AZone');
      expect(AppClock.systemTimezoneName, isNull, reason: '非法名回退');
    });

    test('应用时区优先于显式系统时区', () {
      AppClock.setTimezone('Asia/Shanghai');
      AppClock.syncSystemTimezone('America/New_York');
      final t = AppClock.at(2026, 8, 18, 9, 0);
      expect(
        t.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 18, 1, 0).millisecondsSinceEpoch,
        reason: '上海 UTC+8 09:00 = 01:00Z（应用时区优先）',
      );
    });
  });

  group('setNow 测试时钟注入', () {
    test('注入后 now() 返回注入值，复位后恢复真实时间', () {
      final fixed = DateTime(2026, 8, 20, 10, 0);
      AppClock.setNow(fixed);
      expect(AppClock.now(), fixed);
      expect(AppClock.now().millisecondsSinceEpoch, fixed.millisecondsSinceEpoch);
      AppClock.setNow(null);
      // 复位后与真实时间差小于 1 分钟（不精确断言具体值）
      expect(
        AppClock.now().difference(DateTime.now()).inMinutes.abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('注入值不被应用时区重解释（原样返回）', () {
      AppClock.setTimezone('America/New_York');
      final fixed = DateTime.utc(2026, 8, 20, 10, 0);
      AppClock.setNow(fixed);
      expect(AppClock.now(), fixed);
      expect(AppClock.now().isUtc, isTrue);
    });
  });
}
