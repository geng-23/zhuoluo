import 'package:zhuoluo/core/utils/app_clock.dart';
/// 解析结果
///
/// [date] 命中日期（可能为 null）
/// [time] 命中时间（可能为 null）
/// [rrule] 重复规则（可能为空）
/// [endTime] 结束时间（用于时长推断，可能为 null）
/// [matched] 是否解析到任何时间信息
class ParseResult {
  final DateTime? date;
  final TimeOfDay? time;
  final String rrule;
  final TimeOfDay? endTime;
  final bool matched;

  ParseResult({
    this.date,
    this.time,
    this.rrule = '',
    this.endTime,
    required this.matched,
  });
}

/// 中文自然语言时间解析器
///
/// 支持（丰富表达，参考设计文档 Q46）：
/// - 今天/明天/后天/昨天
/// - 周一~周日、周X、礼拜X、星期X、这周X、下周X、每X
/// - 具体时间：9点、9:30、下午3点、晚上8点、中午12点（数字与中文数字均可：五点、五点半、下午三点）
/// - 日期：8月10日、八月十日、2026-08-10、8/10、五号
/// - 相对：3天后、三天后、下周一
/// - 重复：每天、每周五、每3天、每一周、每两个月、每月1号、每月五号
/// - 组合：明天下午3点、每周五晚上8点
class ChineseDateParser {
  static final ChineseDateParser instance = ChineseDateParser._();

  ChineseDateParser._();

  static const _weekdayNames = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '日': 7,
    '天': 7,
  };

  /// 数字或中文数字匹配模式：1~3 位（时间、日号等上下文；中文支持"二十二"）
  static const _numN3 = r'(?:[0-9]{1,2}|[零一二三四五六七八九十两]{1,3})';
  /// 数字或中文数字匹配模式：任意位（重复间隔、N天后等上下文）
  static const _numAll = r'(?:[0-9]+|[零一二三四五六七八九十两]+)';

  static const _cnDigits = {
    '零': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };

  /// 解析输入文本
  ParseResult parse(String input, {DateTime? now}) {
    final base = now ?? AppClock.now();
    final today = AppClock.at(base.year, base.month, base.day);
    String rrule = '';
    DateTime? date;
    TimeOfDay? time;
    TimeOfDay? endTime;
    bool matched = false;
    var rest = input;

    // ---- 重复规则 ----
    if (rest.contains('每天')) {
      rrule = 'FREQ=DAILY';
      matched = true;
      rest = rest.replaceAll('每天', '');
    } else if (rest.contains('每周')) {
      final m = RegExp(r'每周([一二三四五六日天])').firstMatch(rest);
      if (m != null) {
        final d = _weekdayNames[m.group(1)!]!;
        rrule = 'FREQ=WEEKLY;BYDAY=${_weekdayCode(d)}';
        // 同时设置首个实例日期（本周未到的取本周，已过的取下周）
        var diff = d - today.weekday;
        if (diff < 0) diff += 7;
        date = today.add(Duration(days: diff));
        matched = true;
        rest = rest.replaceAll(m.group(0)!, '');
      }
    } else if (RegExp(r'每(' + _numAll + r')个?(周|月|天)([一二三四五六日天])?')
        .hasMatch(rest)) {
      // 每N天/周/月（数字或中文数字均可："每3天"、"每一周"、"每两个月"）
      final m = RegExp(r'每(' + _numAll + r')个?(周|月|天)([一二三四五六日天])?')
          .firstMatch(rest)!;
      final n = _toInt(m.group(1)!);
      if (n != null && n >= 1) {
        final unit = m.group(2)!;
        if (unit == '天') {
          rrule = 'FREQ=DAILY;INTERVAL=$n';
        } else if (unit == '周') {
          // 无 BYDAY 的 WEEKLY 会被展开器按默认周一解析 → 实例错落周一；
          // 补 BYDAY=起始星期（"每2周"从今天起；"每2周三"显式星期三）
          final wd =
              m.group(3) != null ? _weekdayNames[m.group(3)!]! : today.weekday;
          rrule = 'FREQ=WEEKLY;INTERVAL=$n;BYDAY=${_weekdayCode(wd)}';
          if (m.group(3) != null) {
            // 带星期：首个实例日期取本周未到/已过取下周（与"每周X"一致）
            var diff = wd - today.weekday;
            if (diff < 0) diff += 7;
            date = today.add(Duration(days: diff));
          }
        } else {
          rrule = 'FREQ=MONTHLY;INTERVAL=$n';
        }
        matched = true;
        rest = rest.replaceAll(m.group(0)!, '');
      }
    } else if (RegExp(r'每月(' + _numAll + r')号?').hasMatch(rest)) {
      final m = RegExp(r'每月(' + _numAll + r')号?').firstMatch(rest)!;
      final n = _toInt(m.group(1)!);
      if (n != null && n >= 1) {
        rrule = 'FREQ=MONTHLY;BYMONTHDAY=$n';
        matched = true;
        rest = rest.replaceAll(m.group(0)!, '');
      }
    }

    // ---- 具体日期 ----
    // 昨天
    if (rest.contains('昨天') && date == null) {
      date = today.subtract(const Duration(days: 1));
      matched = true;
      rest = rest.replaceAll('昨天', '');
    }
    // 今天
    if (rest.contains('今天') && date == null) {
      date = today;
      matched = true;
      rest = rest.replaceAll('今天', '');
    }
    // 明天
    if (rest.contains('明天') && date == null) {
      date = today.add(const Duration(days: 1));
      matched = true;
      rest = rest.replaceAll('明天', '');
    }
    // 大后天（必须先于"后天"匹配，否则"大后天"会先命中"后天"）
    if (rest.contains('大后天') && date == null) {
      date = today.add(const Duration(days: 3));
      matched = true;
      rest = rest.replaceAll('大后天', '');
    }
    // 后天
    if (rest.contains('后天') && date == null) {
      date = today.add(const Duration(days: 2));
      matched = true;
      rest = rest.replaceAll('后天', '');
    }
    // N天后（仅显式"后/之后"才解析为相对日期，裸"N天"不吞语义；
    // 数字或中文数字均可："3天后"、"三天后"）
    if (date == null) {
      final m = RegExp(r'(' + _numAll + r')天(?:之)?后').firstMatch(rest);
      if (m != null) {
        final n = _toInt(m.group(1)!);
        if (n != null && n >= 1) {
          date = today.add(Duration(days: n));
          matched = true;
          rest = rest.replaceAll(m.group(0)!, '');
        }
      }
    }
    // 下周X / 这周X
    if (date == null) {
      final m = RegExp(r'([下本这])周([一二三四五六日天])').firstMatch(rest);
      if (m != null) {
        final wd = _weekdayNames[m.group(2)!]!;
        final thisWeekMonday = today.subtract(
          Duration(days: today.weekday - 1),
        );
        final offset = (wd - 1) - (today.weekday - 1);
        if (m.group(1) == '下' || m.group(1) == '本') {
          date = m.group(1) == '下'
              ? thisWeekMonday.add(Duration(days: 7 + (wd - 1)))
              : today.add(Duration(days: offset < 0 ? offset + 7 : offset));
        } else {
          date = today.add(Duration(days: offset));
        }
        matched = true;
        rest = rest.replaceAll(m.group(0)!, '');
      }
    }
    // 周X / 星期X / 礼拜X（无修饰时取本周或下周最近的）
    if (date == null) {
      final m = RegExp(r'(?:周|星期|礼拜)([一二三四五六日天])').firstMatch(rest);
      if (m != null) {
        final wd = _weekdayNames[m.group(1)!]!;
        var diff = wd - today.weekday;
        if (diff < 0) diff += 7; // 本周已过的取下周；今天则保持今天
        date = today.add(Duration(days: diff));
        matched = true;
        rest = rest.replaceAll(m.group(0)!, '');
      }
    }
    // M月D日 / M月D号 / M/D（数字与中文数字均可："8月10日"、"八月十日"）
    if (date == null) {
      final m = RegExp(
        r'(' + _numN3 + r')月(' + _numN3 + r')[日号]?',
      ).firstMatch(rest);
      if (m != null) {
        final month = _toInt(m.group(1)!);
        final day = _toInt(m.group(2)!);
        if (month != null && day != null) {
          // 校验非法日期（如 13月40号），Dart DateTime 会自动进位，
          // 必须构造后回读校验，非法则忽略该匹配
          final v = _tryDate(base.year, month, day);
          if (v != null) {
            date = month < base.month
                ? AppClock.at(base.year + 1, month, day)
                : v;
            matched = true;
            rest = rest.replaceAll(m.group(0)!, '');
          }
        }
      }
    }
    // YYYY-MM-DD / YYYY/M/D
    if (date == null) {
      final m = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(rest);
      if (m != null) {
        date = _tryDate(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
        );
        if (date != null) {
          matched = true;
          rest = rest.replaceAll(m.group(0)!, '');
        }
      }
    }
    // 下个月月底 / 下个月底 / 下月底 → 下月最后一天
    // 必须先于"月底"分支，否则"下个月月底"命中当月月底
    if (date == null) {
      final m = RegExp(r'下个月?月底|下个月?底').firstMatch(rest);
      if (m != null) {
        final nextMonth = base.month + 1;
        final y = nextMonth > 12 ? base.year + 1 : base.year;
        final m1 = nextMonth > 12 ? 1 : nextMonth;
        date = AppClock.at(y, m1 + 1, 0);
        matched = true;
        rest = rest.replaceAll(m.group(0)!, '');
      }
    }
    // 月底
    if (date == null && rest.contains('月底')) {
      date = AppClock.at(base.year, base.month + 1, 0);
      matched = true;
      rest = rest.replaceAll('月底', '');
    }
    // 下个月N号
    if (date == null) {
      final m = RegExp(
        r'下个月?(' + _numN3 + r')[日号]?',
      ).firstMatch(rest);
      if (m != null) {
        final day = _toInt(m.group(1)!);
        if (day != null && day >= 1) {
          final nextMonth = base.month + 1;
          date = _tryDate(
            nextMonth > 12 ? base.year + 1 : base.year,
            nextMonth > 12 ? 1 : nextMonth,
            day,
          );
          if (date != null) {
            matched = true;
            rest = rest.replaceAll(m.group(0)!, '');
          }
        }
      }
    }
    // 这个月N号 / N号
    if (date == null) {
      final m = RegExp(
        r'(?:这个月)?(' + _numN3 + r')[日号]',
      ).firstMatch(rest);
      if (m != null) {
        final day = _toInt(m.group(1)!);
        if (day != null && day >= 1) {
          final v = _tryDate(base.year, base.month, day);
          if (v != null) {
            date = day >= base.day
                ? v
                : AppClock.at(base.year, base.month + 1, day);
            matched = true;
            rest = rest.replaceAll(m.group(0)!, '');
          }
        }
      }
    }

    // ---- 时间 ----
    // 上午/下午/晚上/中午/早上 + N点半 / N点N分 / N点 / N:N
    // 数字与中文数字均可（五点、五点半、下午三点、晚上十二点）
    // 注意"半"分支必须带捕获组，否则匹配"半"时 group(3) 为 null
    // `下` 视为"下午"的缩写（"下3点"=15:00），需排在"下午"之后避免抢先
    String? startPeriod;
    var startIsMidnight = false;
    final m2 = RegExp(
      '(上午|下午|晚上|傍晚|中午|早上|早晨|凌晨|下)?'
      '($_numN3)[点时]'
      '(?:($_numN3)分?|(半))?'
      '|([0-9]{1,2}):([0-9]{2})',
    ).firstMatch(rest);
    if (m2 != null) {
      int? hour;
      var minute = 0;
      if (m2.group(5) != null) {
        hour = int.parse(m2.group(5)!);
        minute = int.parse(m2.group(6)!);
      } else {
        hour = _toInt(m2.group(2)!);
        if (hour != null) {
          // 支持"点半"（如 3点半 = 03:30）；中文"五点半"=05:30
          final g3 = m2.group(3);
          final g4 = m2.group(4);
          minute = g4 != null ? 30 : (g3 == null ? 0 : (_toInt(g3) ?? 0));
          hour = _applyPeriod(m2.group(1), hour);
        }
      }
      if (hour != null && hour <= 23 && minute <= 59) {
        time = TimeOfDay(hour: hour, minute: minute);
        startPeriod = m2.group(1);
        // 起始为午夜（晚上/傍晚/凌晨 12 点转 0 点）时，结束不继承 +12
        startIsMidnight =
            (m2.group(1) == '晚上' ||
                    m2.group(1) == '傍晚' ||
                    m2.group(1) == '凌晨') &&
                hour == 0;
        matched = true;
        rest = rest.replaceAll(m2.group(0)!, '');
      }
    } else {
      // 纯"N点"可能被上面正则漏掉的情况（如"3点"）
      final m3 = RegExp(
        r'(' + _numN3 + r')[点时]',
      ).firstMatch(rest);
      if (m3 != null) {
        final h = _toInt(m3.group(1)!);
        if (h != null && h <= 23) {
          time = TimeOfDay(hour: h, minute: 0);
          matched = true;
          rest = rest.replaceAll(m3.group(0)!, '');
        }
      }
    }

    // ---- 结束时间（用于时长）----
    // 结束时间默认继承起始时段（"下午3点到5点"=15:00-17:00，
    // 此前 5 点被当凌晨 → 生成跨天 14+ 小时任务）；
    // 仅当继承后仍 <= 起始才视为次日凌晨（"晚上11点到1点"=23:00-01:00）。
    // 起始为午夜（"晚上12点"）时结束不继承 +12，保持凌晨语义。
    final mEnd = RegExp(
      '到(上午|下午|晚上|傍晚|中午|早上|早晨|凌晨|下)?'
      '($_numN3)[点时]'
      '(?:($_numN3)分?|(半))?',
    ).firstMatch(rest);
    if (mEnd != null && time != null) {
      var eh = _toInt(mEnd.group(2)!) ?? 0;
      final em = mEnd.group(4) != null
          ? 30
          : ((mEnd.group(3) == null) ? 0 : (_toInt(mEnd.group(3)!) ?? 0));
      final rawEnd = eh;
      final endPeriod = mEnd.group(1);
      if (endPeriod != null) {
        eh = _applyPeriod(endPeriod, eh);
      } else if (!startIsMidnight && startPeriod != null) {
        eh = _applyPeriod(startPeriod, eh);
      }
      if (eh <= time.hour) {
        // 次日凌晨（保持原时刻，调用方按 eh < start 跨天处理）
        eh = rawEnd;
      }
      endTime = TimeOfDay(hour: eh, minute: em);
    }

    return ParseResult(
      date: date,
      time: time,
      rrule: rrule,
      endTime: endTime,
      matched: matched,
    );
  }

  static String _weekdayCode(int wd) {
    const map = {1: 'MO', 2: 'TU', 3: 'WE', 4: 'TH', 5: 'FR', 6: 'SA', 7: 'SU'};
    return map[wd] ?? 'MO';
  }

  /// 按时段偏移小时数：下午/下 → +12；晚上/傍晚 12 点 → 0（午夜）；
  /// 晚上/傍晚 → +12；中午 11 点前 → +12；凌晨 12 点 → 0；上午/早上/早晨不变
  static int _applyPeriod(String? period, int hour) {
    if (period == null) return hour;
    switch (period) {
      case '下午':
      case '下':
        return hour < 12 ? hour + 12 : hour;
      case '晚上':
      case '傍晚':
        if (hour == 12) return 0;
        return hour < 12 ? hour + 12 : hour;
      case '中午':
        return hour < 11 ? hour + 12 : hour;
      case '凌晨':
        return hour == 12 ? 0 : hour;
      default: // 上午/早上/早晨
        return hour;
    }
  }

  /// 数字或中文数字 → int（中文支持 0~99、"两"、"X十Y"，非法返回 null）
  static int? _toInt(String s) {
    final d = int.tryParse(s);
    if (d != null) return d;
    return _cnToInt(s);
  }

  static int? _cnToInt(String s) {
    s = s.replaceAll('零', '');
    if (s.isEmpty) return null;
    if (s == '十') return 10; // 单个"十"不在 _cnDigits 表中，需特判
    if (s.length == 1) return _cnDigits[s];
    var result = 0;
    var i = 0;
    if (s.startsWith('十')) {
      result = 10; // 十 / 十一 ~ 十九
      i = 1;
    } else if (s[1] == '十') {
      final tens = _cnDigits[s[0]];
      if (tens == null || tens == 0) return null;
      result = tens * 10; // 二十 ~ 九十（+"个位"）
      i = 2;
    } else {
      return null;
    }
    if (i < s.length) {
      final d = _cnDigits[s[i]];
      if (d == null) return null;
      result += d;
    }
    return result;
  }

  /// 校验日期合法性（Dart DateTime 对非法月/日会自动进位，
  /// 如 13月40号 → 次年2月9日，必须构造后回读校验），非法返回 null
  static DateTime? _tryDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final d = AppClock.at(year, month, day);
    if (d.year != year || d.month != month || d.day != day) return null;
    return d;
  }
}

/// 时间段（时、分），避免依赖 material 包的 TimeOfDay（纯逻辑可用）
class TimeOfDay {
  final int hour;
  final int minute;

  const TimeOfDay({required this.hour, required this.minute});

  int get inMinutes => hour * 60 + minute;
}
