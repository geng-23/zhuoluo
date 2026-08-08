/// RRULE 展开服务（简化实现：支持 FREQ/INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY）
///
/// 参考设计文档：完整 RRULE（自定义间隔 + 结束 + 单次例外）
/// 例外由数据库层（task_exceptions）处理，此处仅判断"某日期是否命中规则"。
class RruleService {
  RruleService._();

  static final RruleService instance = RruleService._();

  /// 解析 RRULE 字符串为规则对象
  Rrule parse(String rrule) {
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

  DateTime? _parseUntil(String s) {
    if (s.contains('T')) {
      return DateTime.tryParse(s);
    }
    // YYYYMMDD 格式：解析为当日结束（23:59:59.999）。
    // P1-B：定时实例带时分（如 09:00），若解析为当日 00:00，
    // `_withinRule` 的 d.isAfter(until) 会把结束日当天的实例排除。
    if (s.length == 8) {
      return DateTime(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
      ).add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));
    }
    return DateTime.tryParse(s);
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
    final rule = parse(rrule);
    final result = <DateTime>[];
    var emitted = 0;

    // 返回是否继续遍历
    bool emit(DateTime d) {
      if (d.isBefore(start) && !_sameDay(d, start)) return true;
      if (!_withinRule(d, rule)) return false; // UNTIL 之后不再有实例
      if (rule.count != null && emitted >= rule.count!) return false;
      emitted++;
      if (from != null && d.isBefore(from)) return true;
      if (to != null && d.isAfter(to)) return false; // 超出窗口上界
      result.add(d);
      return result.length < limit;
    }

    // 遍历上限：覆盖窗口跨度 + 目标数量，并防 INTERVAL=0 等非法规则死循环
    final spanDays = (to ?? from ?? start)
        .difference(start)
        .inDays
        .clamp(0, 1 << 31);
    final step = switch (rule.freq) {
      'WEEKLY' => (rule.interval > 0 ? rule.interval : 1) * 7,
      'MONTHLY' => (rule.interval > 0 ? rule.interval : 1) * 31,
      'YEARLY' => (rule.interval > 0 ? rule.interval : 1) * 366,
      _ => (rule.interval > 0 ? rule.interval : 1),
    };
    final maxIter = 10 + (spanDays > 0 ? spanDays ~/ step : 0) + limit;

    if (rule.freq == 'DAILY') {
      for (var i = 0; i < maxIter; i++) {
        if (!emit(
          start.add(
            Duration(days: i * (rule.interval > 0 ? rule.interval : 1)),
          ),
        )) {
          break;
        }
      }
    } else if (rule.freq == 'WEEKLY') {
      // P0-16：无 BYDAY 时默认锚点星期（此前固定周一，旧"每N周"任务错落周一；
      // 与解析器"每N周补 BYDAY=起始星期"语义一致）
      final days = rule.byDay ?? [_byDayCode(start.weekday)];
      // 从 start 所在周周一起算
      final monday = DateTime(
        start.year,
        start.month,
        start.day,
      ).subtract(Duration(days: start.weekday - 1));
      for (var i = 0; i < maxIter; i++) {
        final base = monday.add(
          Duration(days: i * 7 * (rule.interval > 0 ? rule.interval : 1)),
        );
        for (final d in days) {
          final day = base.add(Duration(days: _weekdayIndex(d)));
          if (!emit(day)) return result;
        }
      }
    } else if (rule.freq == 'MONTHLY') {
      final mds = (rule.byMonthDay?.isNotEmpty ?? false)
          ? (List<int>.from(rule.byMonthDay!)..sort())
          : [start.day];
      final interval = rule.interval > 0 ? rule.interval : 1;
      for (var i = 0; i < maxIter; i++) {
        final targetMonth = start.month + i * interval;
        final targetYear = start.year + (targetMonth - 1) ~/ 12;
        final targetMonthOfYear = (targetMonth - 1) % 12 + 1;
        for (final md in mds) {
          final d = DateTime(targetYear, targetMonthOfYear, md);
          // 无效日（如 31 号遇到小月）被 DateTime 自动进位，校验后跳过
          if (d.month != targetMonthOfYear || d.year != targetYear) continue;
          if (!emit(d)) return result;
        }
      }
    } else if (rule.freq == 'YEARLY') {
      for (var i = 0; i < maxIter; i++) {
        final d = DateTime(
          start.year + i * (rule.interval > 0 ? rule.interval : 1),
          start.month,
          start.day,
        );
        if (!emit(d)) return result;
      }
    }
    return result;
  }

  /// 从 [anchor] 日起（含）第一个命中规则的实例日期；一年内不命中返回 null。
  /// 用于"开始日期自动吸附到规则首个实例"（计划时间与规则不匹配时）。
  /// 内部按当天 00:00 归一：锚点带时分时，当天的实例不应被 from 过滤掉。
  DateTime? firstHitOnOrAfter(DateTime anchor, String rrule) {
    final day = DateTime(anchor.year, anchor.month, anchor.day);
    final hits = expand(
      day,
      rrule,
      from: day,
      to: day.add(const Duration(days: 370)),
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
    final rule = parse(rrule);
    final day = DateTime(anchor.year, anchor.month, anchor.day);
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
    final from = day.subtract(Duration(days: windowDays));
    final prevHits = expand(from, rrule, from: from, to: day);
    final prev = prevHits.isEmpty ? null : prevHits.last;
    if (prev == null) return next;
    final dNext = day.difference(next).inDays.abs();
    final dPrev = day.difference(prev).inDays.abs();
    return dPrev <= dNext ? prev : next;
  }

  /// 判断 [date] 是否命中规则（含 COUNT/UNTIL 边界）
  bool hitsOn(String rrule, DateTime start, DateTime date) {
    final rule = parse(rrule);
    if (date.isBefore(start) && !_sameDay(date, start)) return false;
    if (!_withinRule(date, rule)) return false;
    if (rule.count != null) {
      // 展开到 date 为止；若 date 被 COUNT 截断（第 count+1 个及以后）则不命中
      // A13：to 必须覆盖 date 当天——实例带时分（如 07:50）大于 date 的 00:00，
      // 用 to: date 会被 expand 的 to 过滤，COUNT 规则下的时段任务当天
      // 误判不命中（全天任务 00:00 恰好不被过滤，表现为"全天显示时段不显示"）
      final upTo = expand(
        start,
        rrule,
        to: DateTime(date.year, date.month, date.day + 1),
        limit: rule.count! + 1,
      );
      final inCount = upTo.any((d) => _sameDay(d, date));
      if (!inCount) return false;
    }
    // FREQ 匹配
    switch (rule.freq) {
      case 'DAILY':
        // 天数差必须按"日"归一：dateKey 是 00:00 而 start 带时分，
        // 直接用 inDays 会让间隔>1 的实例错位（如 20:00 起的每2天任务）
        final startDay = DateTime(start.year, start.month, start.day);
        final dateDay = DateTime(date.year, date.month, date.day);
        return dateDay.difference(startDay).inDays %
                (rule.interval > 0 ? rule.interval : 1) ==
            0;
      case 'WEEKLY':
        final days = rule.byDay ?? [_byDayCode(start.weekday)];
        final offsets = days.map(_weekdayIndex).toSet();
        if (!offsets.contains(date.weekday - 1)) return false;
        // 从 start 所在周周一起算周差
        final startMonday = DateTime(
          start.year,
          start.month,
          start.day,
        ).subtract(Duration(days: start.weekday - 1));
        final weeks = date.difference(startMonday).inDays ~/ 7;
        return weeks % (rule.interval > 0 ? rule.interval : 1) == 0;
      case 'MONTHLY':
        if (rule.byMonthDay != null && rule.byMonthDay!.isNotEmpty) {
          return rule.byMonthDay!.contains(date.day) &&
              ((date.year - start.year) * 12 + (date.month - start.month)) %
                      (rule.interval > 0 ? rule.interval : 1) ==
                  0;
        }
        return date.day == start.day &&
            ((date.year - start.year) * 12 + (date.month - start.month)) %
                    (rule.interval > 0 ? rule.interval : 1) ==
                0;
      case 'YEARLY':
        return date.month == start.month &&
            date.day == start.day &&
            (date.year - start.year) %
                    (rule.interval > 0 ? rule.interval : 1) ==
                0;
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
