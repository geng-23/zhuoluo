import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

import '../support/fake_notification_scheduler.dart';

/// 跨时区语义测试：应用时区 ≠ 系统时区时，
/// 任务墙上时间/提醒基准/RRULE 命中/完成记录归一化/日历按天索引
/// 必须按应用时区解释，不得出现偏移。
void main() {
  late AppDatabase db;

  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 应用时区固定为 America/New_York（UTC-4/-5）——本机系统时区为
    // Asia/Shanghai（UTC+8），两者相差 12 小时，能真实暴露跨时区偏移。
    // 此前用 Asia/Shanghai 与系统时区相同，测试形同虚设。
    AppClock.setTimezone('America/New_York');
  });

  tearDown(() async {
    AppClock.setTimezone(null);
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    required DateTime start,
    required String rrule,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      planStart: Value(start),
      planEnd: Value(start.add(const Duration(hours: 1))),
      rrule: Value(rrule),
      createdAt: AppClock.now(),
    ));
  }

  test('AppClock.at 构造的墙上时间为应用时区绝对时刻', () {
    // 纽约（夏令时 UTC-4）2026-08-10 09:00 = UTC 2026-08-10 13:00
    final t = AppClock.at(2026, 8, 10, 9, 0);
    final utc = DateTime.utc(2026, 8, 10, 13, 0);
    expect(t.millisecondsSinceEpoch, utc.millisecondsSinceEpoch,
        reason: '应用时区墙上时间对应的绝对时刻应等于 UTC 换算值');
    expect(t.hour, 9, reason: '字段按应用时区解释');
  });

  test('创建每天 15:00 任务：planStart 绝对时刻为应用时区 15:00', () async {
    // 系统时区（UTC+8）下普通 DateTime(2026,8,10,15,0) = UTC 07:00；
    // 写入侧若按应用时区（纽约 UTC-4），应为 UTC 19:00（纽约 15:00）
    final id = await insertTask(
      title: '每日打卡',
      start: AppClock.at(2026, 8, 10, 15, 0),
      rrule: 'FREQ=DAILY',
    );
    final t = (await db.getTask(id))!;
    expect(
      t.planStart!.millisecondsSinceEpoch,
      DateTime.utc(2026, 8, 10, 19, 0).millisecondsSinceEpoch,
      reason: '写入的绝对时刻 = 应用时区 15:00（= UTC 19:00）',
    );
    final asApp = AppClock.asApp(t.planStart!);
    expect(asApp.hour, 15,
        reason: '读回后按应用时区解释字段应为 15:00');
  });

  test('reminderTriggerAt：每天 09:00 任务的提醒基准按应用时区', () {
    final task = Task(
      id: 1,
      listId: 1,
      parentId: null,
      title: '早会',
      note: '',
      quadrant: 4,
      planStart: AppClock.at(2026, 8, 10, 9, 0),
      planEnd: AppClock.at(2026, 8, 10, 10, 0),
      dueTime: null,
      isAllDay: false,
      rrule: 'FREQ=DAILY',
      color: '',
      hasReminder: true,
      hasNote: false,
      sortOrder: 0,
      skippedDates: '[]',
      completedAt: null,
      createdAt: AppClock.now(),
    );
    // 重复任务的提醒基准日为"今天"（AppClock.now 应用时区）
    final trigger = reminderTriggerAt(task, 0);
    expect(trigger, isNotNull);
    final asApp = AppClock.asApp(trigger!);
    expect(asApp.hour, 9, reason: '提醒触发按应用时区 09:00');
    final now = AppClock.now();
    final todayApp = AppClock.at(now.year, now.month, now.day, 9, 0);
    expect(
      trigger.millisecondsSinceEpoch,
      todayApp.millisecondsSinceEpoch,
      reason: '触发绝对时刻 = 应用时区今天 09:00',
    );
    // 与系统时区（UTC+8）视角换算一致：用 timezone 包动态换算纽约 09:00
    // 的 UTC 时刻（夏令时 = 13:00，冬令时 = 14:00），不硬编码偏移
    final nyLoc = tz.getLocation('America/New_York');
    final expectedUtc = tz.TZDateTime(
      nyLoc,
      now.year,
      now.month,
      now.day,
      9,
      0,
    ).toUtc();
    expect(
      trigger.millisecondsSinceEpoch,
      expectedUtc.millisecondsSinceEpoch,
      reason: '纽约 09:00 = UTC 动态换算值',
    );
  });

  test('RRULE 命中按应用时区日期判断（跨日边界）', () {
    // 纽约 2026-08-10 08:00（UTC 2026-08-10 12:00）
    final start = AppClock.at(2026, 8, 10, 8, 0);
    final svc = RruleService.instance;
    // 纽约 8/10 与 8/11 都是命中日
    expect(
      svc.hitsOn(
        'FREQ=DAILY',
        start,
        AppClock.at(2026, 8, 11, 0, 0),
      ),
      isTrue,
      reason: '按应用时区日期命中（8/11 纽约 = 8/11 UTC 04:00）',
    );
    // 用系统时区（UTC+8）视角看 8/10 20:00 UTC（= 纽约 8/10 16:00）命中 8/10
    expect(
      svc.hitsOn(
        'FREQ=DAILY',
        start,
        DateTime.utc(2026, 8, 10, 20, 0),
      ),
      isTrue,
      reason: 'UTC 8/10 20:00 按应用时区是 8/10，应命中',
    );
    // 用系统时区（UTC+8）视角看 8/11 02:00 UTC（= 纽约 8/10 22:00）命中 8/10
    expect(
      svc.hitsOn(
        'FREQ=DAILY',
        start,
        DateTime.utc(2026, 8, 11, 2, 0),
      ),
      isTrue,
      reason: 'UTC 8/11 02:00 按应用时区仍是 8/10（纽约 22:00），应命中',
    );
    // 8/11 纽约 00:00 = UTC 04:00：按应用时区是 8/11，命中
    expect(
      svc.hitsOn(
        'FREQ=DAILY',
        start,
        DateTime.utc(2026, 8, 11, 4, 0),
      ),
      isTrue,
      reason: 'UTC 8/11 04:00 = 纽约 8/11 00:00，应命中',
    );
  });

  test('完成记录归一化：instanceDate 存应用时区 00:00', () async {
    final id = await insertTask(
      title: '每日任务',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    // 完成"纽约 8/11 的实例"（传入带时分的 8/11 05:00 = UTC 8/11 09:00）
    await db.completeInstance(
      id,
      AppClock.at(2026, 8, 11, 5, 0),
    );
    final comps = await db.allCompletionsForBackup();
    final comp = comps.single;
    expect(
      comp.instanceDate.millisecondsSinceEpoch,
      DateTime.utc(2026, 8, 11, 4, 0).millisecondsSinceEpoch,
      reason: '完成记录归一化为应用时区 00:00（纽约 8/11 00:00 = UTC 8/11 04:00）',
    );
    expect(
      await db.isInstanceCompleted(id, AppClock.at(2026, 8, 11)),
      isTrue,
      reason: '按应用时区日期查询命中',
    );
  });

  test('日历按天索引：完成状态 key 按应用时区日期', () async {
    final id = await insertTask(
      title: '每日任务',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    await db.completeInstance(id, AppClock.at(2026, 8, 11));
    // 纽约 8/11 的完成记录，按应用时区窗口查询应命中
    final items = await db.getCalendarItems(
      AppClock.at(2026, 8, 1),
      AppClock.at(2026, 8, 31),
    );
    final aug11 = items.where((i) =>
        AppClock.asApp(i.instanceDate).month == 8 &&
        AppClock.asApp(i.instanceDate).day == 11);
    expect(aug11.length, 1, reason: '纽约 8/11 有一个实例');
    expect(aug11.first.completed, isTrue,
        reason: '纽约 8/11 实例完成状态正确');
  });

  test('统计按天分组：完成记录按应用时区日期归组', () async {
    final id = await insertTask(
      title: '每日任务',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    await db.completeInstance(id, AppClock.at(2026, 8, 11));
    // 月窗口：纽约 2026-08 全月
    final counts = await db.getCompletedCountByDay(
      AppClock.at(2026, 8, 1),
      AppClock.at(2026, 8, 31),
    );
    // 完成记录 completedAt 是"现在"（真实时间），断言当月窗口包含该记录
    // 且 key 按应用时区归一化（纽约 00:00 绝对时刻）
    expect(counts.isNotEmpty, isTrue, reason: '月窗口内应有完成记录');
    final keys = counts.keys.map(AppClock.asApp).toList();
    expect(
      keys.any((k) => k.year == 2026 && k.month == 8),
      isTrue,
      reason: '统计 key 按应用时区解释为 2026-08',
    );
    // 计划数：纽约 8/10 起的每日任务在 8 月窗口展开 22 个实例（8/10-8/31）；
    // 原统计口径对重复任务的 planStart 额外计 1 次（8/10）→ 合计 23
    final planned = await db.getPlannedCountByDay(
      AppClock.at(2026, 8, 1),
      AppClock.at(2026, 8, 31),
    );
    expect(
      planned.values.fold<int>(0, (a, b) => a + b),
      23,
      reason: '重复任务计划数 = 展开 22 + planStart 1（原口径）',
    );
  });

  test('统计分组跨日边界：UTC 8/11 03:00 归到应用时区 8/10（纽约 23:00）', () async {
    final id = await insertTask(
      title: '每日任务',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    // 直接写完成记录：completedAt = UTC 8/11 03:00 = 纽约 8/10 23:00
    // 若统计按系统时区字段分组（UTC+8 上海）会错归到 8/11——回归保护
    await db.insertCompletionRaw(
      TaskCompletionsCompanion.insert(
        taskId: id,
        instanceDate: AppClock.at(2026, 8, 10),
        completedAt: DateTime.utc(2026, 8, 11, 3, 0),
      ),
    );
    final counts = await db.getCompletedCountByDay(
      AppClock.at(2026, 8, 1),
      AppClock.at(2026, 8, 31),
    );
    expect(
      counts[AppClock.at(2026, 8, 10)],
      1,
      reason: 'UTC 8/11 03:00 按应用时区（纽约 8/10 23:00）归到 8/10',
    );
    expect(
      counts.containsKey(AppClock.at(2026, 8, 11)),
      isFalse,
      reason: '不得按系统时区字段错归到 8/11',
    );
  });

  test('端到端：创建→展开→完成→日历状态→统计 全链路按应用时区一致', () async {
    // 纽约 20:00 的每日任务（= UTC 次日 00:00，跨日敏感）
    final id = await insertTask(
      title: '晚读',
      start: AppClock.at(2026, 8, 10, 20, 0),
      rrule: 'FREQ=DAILY',
    );
    // 完成纽约 8/12 实例
    await db.completeInstanceIfHit(id, AppClock.at(2026, 8, 12));
    final items = await db.getCalendarItems(
      AppClock.at(2026, 8, 1),
      AppClock.at(2026, 8, 31),
    );
    final aug12 = items.where(
      (i) => AppClock.asApp(i.instanceDate).day == 12,
    );
    expect(aug12.length, 1, reason: '纽约 8/12 一个实例');
    expect(aug12.first.completed, isTrue, reason: '8/12 已完成');
    final aug13 = items.where(
      (i) => AppClock.asApp(i.instanceDate).day == 13,
    );
    expect(aug13.length, 1, reason: '8/13 一个实例');
    expect(aug13.first.completed, isFalse, reason: '8/13 未完成');
    // 统计按 completedAt（完成时刻=应用时区今天）归组
    final now = AppClock.now();
    final todayKey = AppClock.at(now.year, now.month, now.day);
    final counts = await db.getCompletedCountByDay(
      todayKey.subtract(const Duration(days: 1)),
      todayKey.add(const Duration(days: 1)),
    );
    expect(counts[todayKey], 1,
        reason: '统计按完成时刻（应用时区今天）归组');
  });

  test('reminderTriggerAt：DB 读回任务（系统时区字段）不偏移', () async {
    final id = await insertTask(
      title: '早会',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    final t = (await db.getTask(id))!;
    // t.planStart 是 DB 读回值：绝对时刻正确但字段按系统时区（UTC+8）解释，
    // 取字段前必须按应用时区重新解释（否则纽约 09:00 会读成 21:00）
    final trigger = reminderTriggerAt(t, 0);
    expect(trigger, isNotNull);
    final now = AppClock.now();
    final expected = AppClock.at(now.year, now.month, now.day, 9, 0);
    expect(
      trigger!.millisecondsSinceEpoch,
      expected.millisecondsSinceEpoch,
      reason: 'DB 往返后提醒基准仍为应用时区 09:00（修复前为系统时区 21:00）',
    );
  });

  test('scheduleTask：DB 读回任务的提醒触发时刻按应用时区', () async {
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
    addTearDown(
      () => NotificationService.instance.debugOverrideScheduler = null,
    );
    final id = await insertTask(
      title: '早会',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    await db.insertReminder(
      RemindersCompanion.insert(
        taskId: id,
        remindMinutesBefore: const Value(0),
      ),
    );
    final t = (await db.getTask(id))!;
    final scheduler = ReminderScheduler(db);
    final ok = await scheduler.scheduleTask(t, AppClock.now());
    expect(ok, isTrue, reason: '调度应成功');
    expect(fake.scheduled, isNotEmpty,
        reason: '93 天窗口内应有实例通知');
    final a = AppClock.asApp(fake.scheduled.first.when);
    expect(a.hour, 9, reason: '通知时刻为应用时区 09:00（修复前为 21:00）');
    expect(a.minute, 0);
  });
}
