import 'package:zhuoluo/core/utils/app_clock.dart';

/// RRULE 展开服务（简化实现：支持 FREQ/INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY）
///
/// 参考设计文档：完整 RRULE（自定义间隔 + 结束 + 单次例外）
/// 例外由数据库层（task_exceptions）处理，此处仅判断"某日期是否命中规则"。
///
///  统一时间模型：所有入口参数先经 `AppClock.asApp()` 按应用时区解释，
/// 内部日期字段（year/month/day/weekday）与构造（AppClock.at）均按应用时区，
/// 绝对时刻运算（Duration/difference）不受影响；未设置时区时行为不变。
class RruleService {
  RruleService._();

  static final RruleService instance = RruleService._();

  /// parse 结果 LRU 缓存：Rrule 不可变，相同 rrule 字符串复用解析结果，
  /// 避免日历逐日/排期窗口等高频路径反复正则解析（无限期规则多时性能瓶颈）。
  final Map<String, Rrule> _parseCache = {};
  static const int _parseCacheLimit = 128;

  /// 解析 RRULE 字符串为规则对象
  Rrule parse(String rrule) {
    final cached = _parseCache.remove(rrule);
    if (cached != null) {
      _parseCache[rrule] = cached; // 命中置顶（LRU）
      return cached;
    }
    final rule = _parseUncached(rrule);
    _parseCache[rrule] = rule;
    while (_parseCache.length > _parseCacheLimit) {
      _parseCache.remove(_parseCache.keys.first);
    }
    return rule;
  }

  Rrule _parseUncached(String rrule) {
    final parts = <String, String>{};
    for (final seg in rrule.split(';')) {
      final idx = seg.indexOf('=');
      if (idx > 0) {
        parts[seg.substring(0, idx).toUpperCase()] = seg.substring(idx + 1);
      }
    }
    return Rrule(
      freq: parts['FREQ'] ?? 'DAILY',
      interval: int.tryParse(parts['INTERVAL'] ?? '') ?? 1,
      count: int.tryParse(parts['COUNT'] ?? ''),
      until: parts['UNTIL'] != null ? _parseUntil(parts['UNTIL']!) : null,
      byDay: parts['BYDAY']?.split(','),
      byMonthDay: parts['BYMONTHDAY']
          ?.split(',')
          .map(int.tryParse)
          .whereType<int>()
          .toList(),
    );
  }

  /// 判断"系列是否还有未来实例"时使用的展开窗口天数——
  /// 至少覆盖一个完整周期（按频率与 INTERVAL 计算，多 1 天缓冲避免
  /// 窗口边缘因时分差漏掉实例），下限 370 天。
  /// 长间隔任务（如每 2 年 = 732 天）若用固定 370 天窗口，
  /// 窗口内无实例会被误判"系列结束"从视图/提醒中消失。
  static int windowDaysFor(String rrule) {
    final rule = RruleService.instance.parse(rrule);
    final cycleDays = switch (rule.freq) {
      'WEEKLY' => (rule.interval > 0 ? rule.interval : 1) * 7,
      'MONTHLY' => (rule.interval > 0 ? rule.interval : 1) * 31,
      'YEARLY' => (rule.interval > 0 ? rule.interval : 1) * 366,
      _ => rule.interval > 0 ? rule.interval : 1,
    };
    return cycleDays > 370 ? cycleDays + 1 : 370;
  }

  DateTime? _parseUntil(String s) {
    if (s.contains('T')) {
      // RFC 5545 无分隔符格式：YYYYMMDDTHHMMSSZ（UTC）显式解析
      //（DateTime.tryParse 不支持该格式，解析失败会静默降级为"永不结束"）
      final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
          .firstMatch(s);
      if (m != null) {
        return DateTime.utc(
          int.parse(m[1]!),
          int.parse(m[2]!),
          int.parse(m[3]!),
          int.parse(m[4]!),
          int.parse(m[5]!),
          int.parse(m[6]!),
        );
      }
      final parsed = DateTime.tryParse(s);
      if (parsed != null) return parsed;
      // 无法解析的 UNTIL 视为规则已结束（返回远古日期）：避免静默
      // 降级为"永不结束"；外部导入数据可触发，不抛异常以免破坏加载
      return AppClock.at(1970, 1, 1);
    }
    // YYYYMMDD 格式：解析为当日结束（23:59:59.999），按应用时区解释。
    // 定时实例带时分（如 09:00），若解析为当日 00:00，
    // `_withinRule` 的 d.isAfter(until) 会把结束日当天的实例排除。
    if (s.length == 8) {
      final y = int.parse(s.substring(0, 4));
      final mo = int.parse(s.substring(4, 6));
      final d = int.parse(s.substring(6, 8));
      return AppClock.nextDay(AppClock.at(y, mo, d))
          .subtract(const Duration(milliseconds: 1));
    }
    final parsed = DateTime.tryParse(s);
    if (parsed != null) return parsed;
    return AppClock.at(1970, 1, 1);
  }

  /// 从开始日期展开实例。
  /// [from]/[to]：输出窗口过滤（[to] 含当天，超界即停止；[from] 前的不输出）。
  /// COUNT 截断基于从 start 起的全部实例数（不受 [from] 过滤影响）。
  /// 最多输出 [limit] 个。
  List<DateTime> expand(
    DateTime start,
    String rrule, {
    DateTime? from,
    DateTime? to,
    int limit = 400,
  }) {
    // ：入口统一按应用时区解释（未设置时区 = 原样）
    final s = AppClock.asApp(start);
    final f = from == null ? null : AppClock.asApp(from);
    final t = to == null ? null : AppClock.asApp(to);
    final rule = parse(rrule);
    final result = <DateTime>[];
    var emitted = 0;

    // 返回是否继续遍历
    bool emit(DateTime d) {
      if (d.isBefore(s) && !_sameDay(d, s)) return true;
      if (!_withinRule(d, rule)) return false; // UNTIL 之后不再有实例
      if (rule.count != null && emitted >= rule.count!) return false;
      emitted++;
      if (f != null && d.isBefore(f)) return true;
      if (t != null && d.isAfter(t)) return false; // 超出窗口上界
      result.add(d);
      return result.length < limit;
    }

    // 遍历上限：覆盖窗口跨度 + 目标数量，并防 INTERVAL=0 等非法规则死循环
    final interval = rule.interval > 0 ? rule.interval : 1;
    final spanDays = AppClock.daysBetween(s, t ?? f ?? s).clamp(0, 1 << 31);
    final step = switch (rule.freq) {
      'WEEKLY' => interval * 7,
      'MONTHLY' => interval * 31,
      'YEARLY' => interval * 366,
      _ => interval,
    };
    final maxIter = 10 + (spanDays > 0 ? spanDays ~/ step : 0) + limit;

    // 无 COUNT 规则且给定 from 时，起始迭代索引直接跳到 from 附近的周期。
    // COUNT 规则需精确计数 emitted 不可跳。长期无限期任务（历史实例极多）
    // 此前从创建日逐期迭代到窗口，随使用时长线性变慢；跳跃后迭代次数
    // 收敛为"窗口内周期数"。各 FREQ 用保守的向下取整（不晚于 from），
    // 早于 from 的实例由 emit 的 f 过滤兜底，保证不丢窗口内实例。
    final skipTo = (rule.count == null && f != null) ? f : null;

    if (rule.freq == 'DAILY') {
      var startIdx = 0;
      if (skipTo != null) {
        final diff = AppClock.daysBetween(s, skipTo);
        if (diff > 0) startIdx = (diff / interval).ceil();
      }
      for (var i = startIdx; i < maxIter; i++) {
        if (!emit(AppClock.addCalendarDays(s, i * interval))) break;
      }
    } else if (rule.freq == 'WEEKLY') {
      // 无 BYDAY 时默认锚点星期（此前固定周一，旧"每N周"任务错落周一；
      // 与解析器"每N周补 BYDAY=起始星期"语义一致）
      final days = rule.byDay ?? [_byDayCode(s.weekday)];
      // 从 start 所在周周一起算
      final monday = AppClock.addCalendarDays(
        AppClock.at(s.year, s.month, s.day),
        -(s.weekday - 1),
      );
      var startIdx = 0;
      if (skipTo != null) {
        final diff = AppClock.daysBetween(monday, skipTo);
        if (diff > 0) startIdx = diff ~/ (interval * 7);
      }
      for (var i = startIdx; i < maxIter; i++) {
        final base = AppClock.addCalendarDays(monday, i * 7 * interval);
        for (final d in days) {
          final day = AppClock.addCalendarDays(base, _weekdayIndex(d));
          if (!emit(day)) return result;
        }
      }
    } else if (rule.freq == 'MONTHLY') {
      final mds = (rule.byMonthDay?.isNotEmpty ?? false)
          ? (List<int>.from(rule.byMonthDay!)..sort())
          : [s.day];
      var startIdx = 0;
      if (skipTo != null) {
        final diffMonths =
            (skipTo.year - s.year) * 12 + (skipTo.month - s.month);
        if (diffMonths > 0) startIdx = diffMonths ~/ interval;
      }
      for (var i = startIdx; i < maxIter; i++) {
        final targetMonth = s.month + i * interval;
        final targetYear = s.year + (targetMonth - 1) ~/ 12;
        final targetMonthOfYear = (targetMonth - 1) % 12 + 1;
        for (final md in mds) {
          final d = AppClock.at(targetYear, targetMonthOfYear, md);
          // 无效日（如 31 号遇到小月）被 DateTime 自动进位，校验后跳过
          if (d.month != targetMonthOfYear || d.year != targetYear) continue;
          if (!emit(d)) return result;
        }
      }
    } else if (rule.freq == 'YEARLY') {
      var startIdx = 0;
      if (skipTo != null) {
        final diffYears = skipTo.year - s.year;
        if (diffYears > 0) startIdx = diffYears ~/ interval;
      }
      for (var i = startIdx; i < maxIter; i++) {
        final targetYear = s.year + i * interval;
        final d = AppClock.at(targetYear, s.month, s.day);
        // 无效日（闰日锚点 2/29 遇非闰年）被 DateTime 自动进位到 3/1，
        // 校验后跳过该年——与 MONTHLY 的无效日处理一致，也与 hitsOn 的
        // YEARLY 分支（要求月日完全相等）同口径，避免"日历出现 3/1 实例
        // 但命中/完成判定不命中"的分裂
        if (d.month != s.month || d.day != s.day) continue;
        if (!emit(d)) return result;
      }
    }
    return result;
  }

  /// 从 [anchor] 日起（含）第一个命中规则的实例日期；一年内不命中返回 null。
  /// 用于"开始日期自动吸附到规则首个实例"（计划时间与规则不匹配时）。
  /// 内部按当天 00:00 归一：锚点带时分时，当天的实例不应被 from 过滤掉。
  DateTime? firstHitOnOrAfter(DateTime anchor, String rrule) {
    final a = AppClock.asApp(anchor);
    final day = AppClock.at(a.year, a.month, a.day);
    final hits = expand(
      day,
      rrule,
      from: day,
      to: AppClock.addCalendarDays(day, 370),
      limit: 1,
    );
    return hits.isEmpty ? null : hits.first;
  }

  /// A13：把锚点吸附到**距其最近**的规则命中日（可早于锚点，≤一个周期）。
  ///
  /// 背景：此前创建/改规则/启动修复统一用 firstHitOnOrAfter（未来首个命中日），
  /// 锚点当天不命中规则时（如周三创建"每周一"），吸附结果落在未来 7 天外，
  /// 当前周视图窗口内无实例 → 任务从日历"消失"，用户反复反馈"重复任务不显示"。
  /// 吸附到最近命中日（含过去的本周一）保证创建后当前周立即可见。
  ///
  /// 规则：锚点本身命中 → 原地；COUNT 规则 → 仅向后（向前展开无意义）；
  /// 否则比较"前一个命中日"与"后一个命中日"取天数差更近者。
  DateTime? nearestHitOnOrNear(DateTime anchor, String rrule) {
    final a = AppClock.asApp(anchor);
    final rule = parse(rrule);
    final day = AppClock.at(a.year, a.month, a.day);
    if (hitsOn(rrule, day, day)) return day;
    if (rule.count != null) return firstHitOnOrAfter(day, rrule);
    final next = firstHitOnOrAfter(day, rrule);
    if (next == null) return null;
    // 向前查最近命中日：从 [day - 一个周期] 展开到 day，取最后一个命中
    //（复用 expand，起点周/月/年对齐不影响命中集合）
    final windowDays = switch (rule.freq) {
      'WEEKLY' => (rule.interval > 0 ? rule.interval : 1) * 7,
      'MONTHLY' => (rule.interval > 0 ? rule.interval : 1) * 31,
      'YEARLY' => (rule.interval > 0 ? rule.interval : 1) * 366,
      _ => (rule.interval > 0 ? rule.interval : 1),
    };
    final from = AppClock.addCalendarDays(day, -windowDays);
    final prevHits = expand(from, rrule, from: from, to: day);
    final prev = prevHits.isEmpty ? null : prevHits.last;
    if (prev == null) return next;
    final dNext = AppClock.daysBetween(day, next).abs();
    final dPrev = AppClock.daysBetween(day, prev).abs();
    return dPrev <= dNext ? prev : next;
  }

  /// 锚点吸附统一收口：把任务 planStart 吸附到**距其最近**的规则命中日
  /// （可早于锚点，≤一个周期；规则与 A13 语义见 [nearestHitOnOrNear]）。
  ///
  /// [planStart] 可能来自 DB 读回（字段按系统时区解释），内部先按应用时区
  /// 重新解释再取时分/比较日期，避免"应用时区 ≠ 系统时区"时吸附结果整体
  /// 偏移时区差。返回调整后的应用时区时刻（保持时分）；
  /// 已命中规则/无命中时返回 null（无需调整）。
  DateTime? normalizeAnchor(DateTime planStart, String rrule) {
    final a = AppClock.asApp(planStart);
    final hit = nearestHitOnOrNear(planStart, rrule);
    if (hit == null) return null;
    if (hit.year == a.year && hit.month == a.month && hit.day == a.day) {
      return null; // 锚点已命中规则，无需调整
    }
    return AppClock.at(hit.year, hit.month, hit.day, a.hour, a.minute);
  }

  /// 判断 [date] 是否命中规则（含 COUNT/UNTIL 边界）
  bool hitsOn(String rrule, DateTime start, DateTime date) {
    // ：入口统一按应用时区解释（绝对时刻不变）
    final s = AppClock.asApp(start);
    final d = AppClock.asApp(date);
    final rule = parse(rrule);
    if (d.isBefore(s) && !_sameDay(d, s)) return false;
    if (!_withinRule(d, rule)) return false;
    if (rule.count != null) {
      // 展开到 date 为止；若 date 被 COUNT 截断（第 count+1 个及以后）则不命中
      // A13：to 必须覆盖 date 当天——实例带时分（如 07:50）大于 date 的 00:00，
      // 用 to: date 会被 expand 的 to 过滤，COUNT 规则下的时段任务当天
      // 误判不命中（全天任务 00:00 恰好不被过滤，表现为"全天显示时段不显示"）
      final upTo = expand(
        s,
        rrule,
        to: AppClock.at(d.year, d.month, d.day + 1),
        limit: rule.count! + 1,
      );
      final inCount = upTo.any((x) => _sameDay(x, d));
      if (!inCount) return false;
    }
    // FREQ 匹配
    switch (rule.freq) {
      case 'DAILY':
        // 天数差必须按"日"归一：dateKey 是 00:00 而 start 带时分，
        // 直接用 inDays 会让间隔>1 的实例错位（如 20:00 起的每2天任务），
        // DST 转换日 23h/25h 时长更会被 floor 截断成 0/2
        final startDay = AppClock.at(s.year, s.month, s.day);
        final dateDay = AppClock.at(d.year, d.month, d.day);
        return AppClock.daysBetween(startDay, dateDay) %
                (rule.interval > 0 ? rule.interval : 1) ==
            0;
      case 'WEEKLY':
        final days = rule.byDay ?? [_byDayCode(s.weekday)];
        final offsets = days.map(_weekdayIndex).toSet();
        if (!offsets.contains(d.weekday - 1)) return false;
        // 从 start 所在周周一起算周差（周一基准，DST 安全）
        final startMonday = AppClock.addCalendarDays(
          AppClock.at(s.year, s.month, s.day),
          -(s.weekday - 1),
        );
        final weeks = AppClock.weeksBetweenMonday(startMonday, d);
        return weeks % (rule.interval > 0 ? rule.interval : 1) == 0;
      case 'MONTHLY':
        if (rule.byMonthDay != null && rule.byMonthDay!.isNotEmpty) {
          return rule.byMonthDay!.contains(d.day) &&
              ((d.year - s.year) * 12 + (d.month - s.month)) %
                      (rule.interval > 0 ? rule.interval : 1) ==
                  0;
        }
        return d.day == s.day &&
            ((d.year - s.year) * 12 + (d.month - s.month)) %
                    (rule.interval > 0 ? rule.interval : 1) ==
                0;
      case 'YEARLY':
        return d.month == s.month &&
            d.day == s.day &&
            (d.year - s.year) % (rule.interval > 0 ? rule.interval : 1) == 0;
    }
    return false;
  }

  bool _withinRule(DateTime d, Rrule rule) {
    if (rule.until != null && d.isAfter(rule.until!)) return false;
    return true;
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 周几缩写 → 索引（0=周一）
  int _weekdayIndex(String s) {
    const map = {'MO': 0, 'TU': 1, 'WE': 2, 'TH': 3, 'FR': 4, 'SA': 5, 'SU': 6};
    return map[s] ?? 0;
  }

  /// 星期数字（1=周一）→ 缩写
  String _byDayCode(int weekday) {
    const map = {1: 'MO', 2: 'TU', 3: 'WE', 4: 'TH', 5: 'FR', 6: 'SA', 7: 'SU'};
    return map[weekday] ?? 'MO';
  }
}

class Rrule {
  final String freq;
  final int interval;
  final int? count;
  final DateTime? until;
  final List<String>? byDay;
  final List<int>? byMonthDay;

  Rrule({
    required this.freq,
    required this.interval,
    this.count,
    this.until,
    this.byDay,
    this.byMonthDay,
  });
}
