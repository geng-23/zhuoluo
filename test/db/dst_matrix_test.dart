import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

/// DST 转换日测试矩阵：春/秋转换日附近，通知 ID、窗口边界、RRULE 展开、
/// 解析器相对日期、锚点吸附必须保持"日历日"语义（不受 23h/25h 时长影响）。
void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    AppClock.setNow(DateTime(2026, 8, 20, 10, 0));
  });

  tearDown(() async {
    AppClock.setNow(null);
    AppClock.setTimezone(null);
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    required DateTime start,
    String rrule = '',
    DateTime? end,
    bool isAllDay = false,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      planStart: Value(start),
      planEnd: Value(end ?? start.add(const Duration(hours: 1))),
      isAllDay: Value(isAllDay),
      rrule: Value(rrule),
      createdAt: AppClock.now(),
    ));
  }

  group('通知 ID（America/Los_Angeles，含 DST）', () {
    test('春季转换日（2026-03-08/09）相邻两天 ID 互异', () {
      AppClock.setTimezone('America/Los_Angeles');
      final id1 = NotificationIds.forReminder(1, AppClock.at(2026, 3, 8));
      final id2 = NotificationIds.forReminder(1, AppClock.at(2026, 3, 9));
      expect(id2 - id1, 1, reason: '连续两天日序号必须差 1（修复前同为 69）');
      expect(
        NotificationIds.forHabit(1, AppClock.at(2026, 3, 8)),
        isNot(NotificationIds.forHabit(1, AppClock.at(2026, 3, 9))),
      );
    });

    test('秋季转换日（2026-11-01/02）相邻两天 ID 互异', () {
      AppClock.setTimezone('America/Los_Angeles');
      final id1 = NotificationIds.forReminder(1, AppClock.at(2026, 11, 1));
      final id2 = NotificationIds.forReminder(1, AppClock.at(2026, 11, 2));
      expect(id2 - id1, 1, reason: '秋季回拨日不得跳号');
      expect(
        NotificationIds.forHabit(1, AppClock.at(2026, 11, 1)),
        isNot(NotificationIds.forHabit(1, AppClock.at(2026, 11, 2))),
      );
    });

    test('同日 23:59 与 00:00 归一化后 ID 一致（排期/取消同基准）', () {
      AppClock.setTimezone('America/Los_Angeles');
      final a = NotificationIds.forReminder(1, AppClock.at(2026, 3, 8));
      final b = NotificationIds.forReminder(
        1,
        AppClock.at(2026, 3, 8, 23, 59),
      );
      expect(a, b);
    });
  });

  group('窗口边界（America/New_York，秋季转换日 2026-11-01）', () {
    test('23:30 计划任务必须出现在"今天"窗口（+24h 上界会漏掉）', () async {
      AppClock.setTimezone('America/New_York');
      final id = await insertTask(
        title: '深夜任务',
        start: AppClock.at(2026, 11, 1, 23, 30),
        end: AppClock.at(2026, 11, 1, 23, 45),
      );
      final tasks = await db.getTasksForDate(AppClock.at(2026, 11, 1));
      expect(tasks.map((t) => t.id), contains(id),
          reason: '秋季回拨日 23:00-23:59 的任务不得被排他窗口排除');
      // 次日窗口不得包含它（不跨天）
      final next = await db.getTasksForDate(AppClock.at(2026, 11, 2));
      expect(next.map((t) => t.id), isNot(contains(id)));
    });

    test('23:59 完成的记录计入当天统计（to 排他上界 = 次日 00:00）', () async {
      AppClock.setTimezone('America/New_York');
      final id = await insertTask(
        title: '每日任务',
        start: AppClock.at(2026, 11, 1, 9, 0),
        rrule: 'FREQ=DAILY',
      );
      await db.insertCompletionRaw(
        TaskCompletionsCompanion.insert(
          taskId: id,
          instanceDate: AppClock.at(2026, 11, 1),
          completedAt: AppClock.at(2026, 11, 1, 23, 59),
        ),
      );
      final counts = await db.getCompletedCountByDay(
        AppClock.at(2026, 11, 1),
        AppClock.at(2026, 11, 1),
      );
      expect(counts[AppClock.at(2026, 11, 1)], 1,
          reason: '回拨日 23:59 完成记录归当天（修复前 +24h 上界=23:00 漏计）');
    });

    test('全天任务 planEnd = 次日 00:00（非同日 23:00）', () async {
      AppClock.setTimezone('America/New_York');
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = AppClock.at(2026, 11, 1);
      final id = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '全天',
        planStart: Value(start),
        planEnd: Value(AppClock.nextDay(start)),
        isAllDay: const Value(true),
        createdAt: AppClock.now(),
      ));
      final t = (await db.getTask(id))!;
      expect(AppClock.asApp(t.planEnd!).day, 2,
          reason: '全天占位结束 = 次日 00:00（11/2），不得落在 11/1 23:00');
      // 全天任务在"今天"窗口出现、次日窗口不出现
      final today = await db.getTasksForDate(AppClock.at(2026, 11, 1));
      expect(today.map((x) => x.id), contains(id));
      final tomorrow = await db.getTasksForDate(AppClock.at(2026, 11, 2));
      expect(tomorrow.map((x) => x.id), contains(id),
          reason: '跨天覆盖：全天任务占位 11/1 晚到 11/2 00:00，两天都可见');
    });
  });

  group('RRULE 展开（America/New_York，跨春/秋转换日）', () {
    test('每天任务在 2026 年展开 365 天、2024 闰年 366 天，无缺失无重复', () {
      AppClock.setTimezone('America/New_York');
      final svc = RruleService.instance;
      // to 上界含端点日（2027-01-01），按年过滤后统计当年天数
      final hits2026 = svc.expand(
        AppClock.at(2026, 1, 1),
        'FREQ=DAILY',
        to: AppClock.at(2027, 1, 1),
      );
      final in2026 =
          hits2026.where((d) => AppClock.asApp(d).year == 2026).toList();
      expect(in2026.length, 365);
      expect(in2026.toSet().length, 365, reason: '无重复（跨春季转换日）');
      final hits2024 = svc.expand(
        AppClock.at(2024, 1, 1),
        'FREQ=DAILY',
        to: AppClock.at(2025, 1, 1),
      );
      final in2024 =
          hits2024.where((d) => AppClock.asApp(d).year == 2024).toList();
      expect(in2024.length, 366, reason: '闰年');
      // 秋/春转换日前后每天都各有一个实例
      expect(
        hits2026.where((d) => AppClock.asApp(d).month == 3).length,
        31,
      );
      expect(
        hits2026.where((d) => AppClock.asApp(d).month == 11).length,
        30,
      );
    });

    test('每2天规则跨春季转换日不误命中/漏命中', () {
      AppClock.setTimezone('America/New_York');
      final svc = RruleService.instance;
      // 2026-03-01 起每 2 天：3/9 应命中（差 8 个日历日）；
      // 绝对时长差 7天23h → inDays=7 → 7%2=1 误判不命中
      expect(
        svc.hitsOn(
          'FREQ=DAILY;INTERVAL=2',
          AppClock.at(2026, 3, 1, 9, 0),
          AppClock.at(2026, 3, 9, 9, 0),
        ),
        isTrue,
        reason: '3/1 起的每2天任务，3/9 为第 5 个实例（8 日差），必须命中',
      );
      expect(
        svc.hitsOn(
          'FREQ=DAILY;INTERVAL=2',
          AppClock.at(2026, 3, 1, 9, 0),
          AppClock.at(2026, 3, 10, 9, 0),
        ),
        isFalse,
        reason: '9 日差不是 2 的倍数，不得误命中',
      );
    });

    test('每2周规则跨春季转换日周数差正确', () {
      AppClock.setTimezone('America/New_York');
      final svc = RruleService.instance;
      // 2026-02-23（周一）起每 2 周：3/9（周一）应命中；
      // 绝对时长差 13天23h → inDays~/7=1 → 1%2=1 误判不命中
      expect(
        svc.hitsOn(
          'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO',
          AppClock.at(2026, 2, 23, 9, 0),
          AppClock.at(2026, 3, 9, 9, 0),
        ),
        isTrue,
        reason: '2/23 起的每2周任务，3/9 为下一周期，必须命中',
      );
    });
  });

  group('解析器相对日期（America/New_York，秋季转换日）', () {
    test('11/1 输入"明天"返回 11/2（而非同日 23:00 造成的 11/1）', () {
      AppClock.setTimezone('America/New_York');
      final result = ChineseDateParser.instance.parse(
        '明天下午3点',
        now: AppClock.at(2026, 11, 1, 10, 0),
      );
      final d = AppClock.asApp(result.date!);
      expect(d.month, 11);
      expect(d.day, 2);
      expect(result.time!.hour, 15);
    });

    test('11/1 输入"3天后"返回 11/4', () {
      AppClock.setTimezone('America/New_York');
      final result = ChineseDateParser.instance.parse(
        '3天后',
        now: AppClock.at(2026, 11, 1, 10, 0),
      );
      final d = AppClock.asApp(result.date!);
      expect(d.month, 11);
      expect(d.day, 4);
    });

    test('11/1 输入"昨天"返回 10/31', () {
      AppClock.setTimezone('America/New_York');
      final result = ChineseDateParser.instance.parse(
        '昨天',
        now: AppClock.at(2026, 11, 1, 10, 0),
      );
      final d = AppClock.asApp(result.date!);
      expect(d.month, 10);
      expect(d.day, 31);
    });
  });

  group('应用时区 ≠ 系统时区锚点吸附（系统 LA / 应用 Shanghai）', () {
    test('启动修复保持应用时区墙钟时分（DB 读回值先 asApp）', () async {
      // 应用时区固定上海（UTC+8）；本机/CI 系统时区为 LA（UTC-7，有 DST）。
      // 上海 2026-08-11 09:00 = UTC 8/11 01:00 = LA 8/10 18:00——
      // 若直接取 DB 读回字段（hour=18）会吸附出 18:00，必须按应用时区取 09:00
      AppClock.setTimezone('Asia/Shanghai');
      final id = await insertTask(
        title: '周二锚点',
        start: AppClock.at(2026, 8, 11, 9, 0), // 周二，不命中每周一
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      );
      await db.fixOrphanRecurringAnchors();
      final t = (await db.getTask(id))!;
      final a = AppClock.asApp(t.planStart!);
      expect(a.month, 8);
      expect(a.day, 10, reason: '最近命中日 = 周一 8/10');
      expect(a.hour, 9, reason: '时分按应用时区保持 09:00（修复前为 18:00）');
      expect(a.minute, 0);
    });

    test('创建路径 normalizeAnchor 同样保持应用时区墙钟', () {
      AppClock.setTimezone('Asia/Shanghai');
      // 模拟 UI 回传：上海 2026-08-11 09:00（周二，不命中每周一）
      final ps = AppClock.at(2026, 8, 11, 9, 0);
      final newStart = RruleService.instance.normalizeAnchor(
        ps,
        'FREQ=WEEKLY;BYDAY=MO',
      );
      final a = AppClock.asApp(newStart!);
      expect(a.day, 10);
      expect(a.hour, 9);
    });
  });
}
