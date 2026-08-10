import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/timeline_view.dart';

/// 拖动"时长不跨天"回退（clampStartWithinDay）
/// 时间轴动态起始小时（effectiveStartHourFor）
void main() {
  group('clampStartWithinDay', () {
    test('22:30 拖 2h 任务 → 回退到 21:00（23:00 前结束，不跨午夜）', () {
      final start = DateUtilsEx.clampStartWithinDay(
        DateTime(2026, 8, 8, 22, 30),
        const Duration(hours: 2),
      );
      expect(start.hour, 21);
      expect(start.minute, 0);
    });

    test('23:00 拖 1h 任务 → 回退到 22:00', () {
      final start = DateUtilsEx.clampStartWithinDay(
        DateTime(2026, 8, 8, 23, 0),
        const Duration(hours: 1),
      );
      expect(start.hour, 22);
      expect(start.minute, 0);
    });

    test('16:00 拖 2h 任务 → 不回退', () {
      final start = DateUtilsEx.clampStartWithinDay(
        DateTime(2026, 8, 8, 16, 0),
        const Duration(hours: 2),
      );
      expect(start.hour, 16);
      expect(start.minute, 0);
    });

    test('23:50 拖 1h 任务 → 回退到 22:00（23:00 边界回退到起点）', () {
      final start = DateUtilsEx.clampStartWithinDay(
        DateTime(2026, 8, 8, 23, 50),
        const Duration(hours: 1),
      );
      expect(start.hour, 22);
      expect(start.minute, 0);
    });
  });

  group('effectiveStartHourFor', () {
    final days = [DateTime(2026, 8, 8)];

    Task task({
      int id = 1,
      DateTime? planStart,
      DateTime? planEnd,
      bool isAllDay = false,
    }) =>
        Task(
          id: id,
          listId: 1,
          title: '任务',
          note: '',
          quadrant: 4,
          planStart: planStart,
          planEnd: planEnd,
          dueTime: null,
          isAllDay: isAllDay,
          rrule: '',
          color: '',
          hasReminder: false,
          hasNote: false,
          sortOrder: 0,
          skippedDates: '[]',
          completedAt: null,
          createdAt: DateTime(2026, 1, 1),
        );

    CalendarItem item(Task t, DateTime day) => CalendarItem(
      task: t,
      instanceDate: day,
      completed: false,
      listColor: '#4F8EF7',
    );

    // effectiveStartHourFor 按天分组驱动（与 CalendarController.byDay 同口径）
    Map<int, List<CalendarItem>> grouped(List<CalendarItem> items) {
      final m = <int, List<CalendarItem>>{};
      for (final it in items) {
        m.putIfAbsent(
          it.instanceDate.year * 10000 +
              it.instanceDate.month * 100 +
              it.instanceDate.day,
          () => [],
        ).add(it);
      }
      return m;
    }

    test('无 06:00 前任务 → 保持默认 6', () {
      final t = task(
        planStart: DateTime(2026, 8, 8, 8, 0),
        planEnd: DateTime(2026, 8, 8, 9, 0),
      );
      expect(
        effectiveStartHourFor(byDay: grouped([item(t, days.first)]), days: days),
        6,
      );
    });

    test('05:00 任务 → 起始小时扩展到 5（任务不再隐形）', () {
      final t = task(
        planStart: DateTime(2026, 8, 8, 5, 30),
        planEnd: DateTime(2026, 8, 8, 6, 0),
      );
      expect(
        effectiveStartHourFor(byDay: grouped([item(t, days.first)]), days: days),
        5,
      );
    });

    test('全天任务不计入起始小时', () {
      final t = task(
        planStart: DateTime(2026, 8, 8, 4, 0),
        planEnd: DateTime(2026, 8, 8, 5, 0),
        isAllDay: true,
      );
      expect(
        effectiveStartHourFor(byDay: grouped([item(t, days.first)]), days: days),
        6,
        reason: '全天任务在置顶区，不参与时间轴起始计算',
      );
    });

    test('仅显示范围外的早任务不影响（其它日期 03:00 任务不拉低本周起点）', () {
      final t = task(
        planStart: DateTime(2026, 8, 3, 3, 0),
        planEnd: DateTime(2026, 8, 3, 4, 0),
      );
      expect(
        effectiveStartHourFor(
          byDay: grouped([item(t, DateTime(2026, 8, 3))]), // 实例日在显示范围外
          days: days,
        ),
        6,
        reason: '显示范围外的任务不参与计算',
      );
    });

    test('跨天任务不计入（置顶区）', () {
      final t = task(
        planStart: DateTime(2026, 8, 8, 22, 0),
        planEnd: DateTime(2026, 8, 9, 1, 0),
      );
      expect(
        effectiveStartHourFor(byDay: grouped([item(t, days.first)]), days: days),
        6,
      );
    });

    test('取最早任务小时', () {
      final t1 = task(
        id: 1,
        planStart: DateTime(2026, 8, 8, 4, 30),
        planEnd: DateTime(2026, 8, 8, 5, 0),
      );
      final t2 = task(
        id: 2,
        planStart: DateTime(2026, 8, 8, 5, 0),
        planEnd: DateTime(2026, 8, 8, 6, 0),
      );
      expect(
        effectiveStartHourFor(
          byDay: grouped([item(t1, days.first), item(t2, days.first)]),
          days: days,
        ),
        4,
      );
    });
  });

  group('planRangeText / timeRangeText（跨天消除歧义）', () {
    final now = DateTime.now();

    test('未设置 → 未设置', () {
      expect(DateUtilsEx.planRangeText(null, null), '未设置');
    });

    test('全天 → 仅日期', () {
      final d = DateTime(now.year, now.month, now.day);
      expect(
        DateUtilsEx.planRangeText(
          d,
          d.add(const Duration(days: 1)),
          isAllDay: true,
        ),
        DateUtilsEx.dateCn(d),
      );
    });

    test('同日 → 日期 时分-时分', () {
      final start = DateTime(now.year, now.month, now.day, 14, 0);
      expect(
        DateUtilsEx.planRangeText(start, start.add(const Duration(hours: 1))),
        '${DateUtilsEx.dateCn(start)} 14:00-15:00',
      );
    });

    test('跨天（今天→明天）→ 两端带日期', () {
      final start = DateTime(now.year, now.month, now.day, 22, 0);
      expect(
        DateUtilsEx.planRangeText(start, start.add(const Duration(hours: 8))),
        '今天 22:00 到 明天 06:00',
      );
    });

    test('跨天（远期跨年）→ 两端带完整日期', () {
      expect(
        DateUtilsEx.planRangeText(
          DateTime(2030, 12, 31, 23, 0),
          DateTime(2031, 1, 1, 1, 0),
        ),
        '2030年12月31日 23:00 到 2031年1月1日 01:00',
      );
    });

    test('timeRangeText：同日无日期前缀', () {
      final start = DateTime(now.year, now.month, now.day, 9, 0);
      expect(
        DateUtilsEx.timeRangeText(
          start,
          start.add(const Duration(minutes: 30)),
        ),
        '09:00-09:30',
      );
    });
  });
}
