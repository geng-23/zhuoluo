import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

/// P1-2 跨时区语义测试：应用时区 ≠ 系统时区时，
/// 任务墙上时间/提醒基准/RRULE 命中/完成记录归一化/日历按天索引
/// 必须按应用时区解释，不得出现偏移。
void main() {
  late AppDatabase db;

  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 测试环境系统时区通常为 UTC；固定应用时区为 Asia/Shanghai (UTC+8)
    AppClock.setTimezone('Asia/Shanghai');
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
    // 上海 2026-08-10 09:00 = UTC 2026-08-10 01:00
    final t = AppClock.at(2026, 8, 10, 9, 0);
    final utc = DateTime.utc(2026, 8, 10, 1, 0);
    expect(t.millisecondsSinceEpoch, utc.millisecondsSinceEpoch,
        reason: 'P1-2：应用时区墙上时间对应的绝对时刻应等于 UTC 换算值');
    expect(t.hour, 9, reason: '字段按应用时区解释');
  });

  test('创建每天 15:00 任务：planStart 绝对时刻为上海 15:00', () async {
    // 系统时区（UTC）下普通 DateTime(2026,8,10,15,0) = UTC 15:00；
    // 写入侧若按应用时区，应为 UTC 07:00（上海 15:00）
    final id = await insertTask(
      title: '每日打卡',
      start: AppClock.at(2026, 8, 10, 15, 0),
      rrule: 'FREQ=DAILY',
    );
    final t = (await db.getTask(id))!;
    expect(
      t.planStart!.millisecondsSinceEpoch,
      DateTime.utc(2026, 8, 10, 7, 0).millisecondsSinceEpoch,
      reason: 'P1-2：写入的绝对时刻 = 应用时区 15:00（= UTC 07:00）',
    );
    final asApp = AppClock.asApp(t.planStart!);
    expect(asApp.hour, 15,
        reason: 'P1-2：读回后按应用时区解释字段应为 15:00');
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
    expect(asApp.hour, 9, reason: 'P1-2：提醒触发按应用时区 09:00');
    final now = AppClock.now();
    final todayShanghai = AppClock.at(now.year, now.month, now.day, 9, 0);
    expect(
      trigger.millisecondsSinceEpoch,
      todayShanghai.millisecondsSinceEpoch,
      reason: 'P1-2：触发绝对时刻 = 应用时区今天 09:00',
    );
    // 与系统时区（UTC）视角换算一致：上海 09:00 = UTC 当天 01:00
    expect(
      trigger.millisecondsSinceEpoch,
      DateTime.utc(now.year, now.month, now.day, 1, 0).millisecondsSinceEpoch,
      reason: 'P1-2：上海 09:00 = UTC 当天 01:00',
    );
  });

  test('RRULE 命中按应用时区日期判断（跨日边界）', () {
    // 上海 2026-08-10 08:00（UTC 2026-08-10 00:00）
    final start = AppClock.at(2026, 8, 10, 8, 0);
    final svc = RruleService.instance;
    // 上海 8/10 与 8/11 都是命中日
    expect(
      svc.hitsOn(
        'FREQ=DAILY',
        start,
        AppClock.at(2026, 8, 11, 0, 0),
      ),
      isTrue,
      reason: 'P1-2：按应用时区日期命中（8/11 上海 = 8/10 UTC 16:00）',
    );
    // 用系统时区（UTC）视角看 8/10 21:00（= 上海 8/11 05:00）也应命中 8/11
    expect(
      svc.hitsOn(
        'FREQ=DAILY',
        start,
        DateTime.utc(2026, 8, 10, 21, 0),
      ),
      isTrue,
      reason: 'P1-2：UTC 8/10 21:00 按应用时区是 8/11，应命中',
    );
  });

  test('完成记录归一化：instanceDate 存应用时区 00:00', () async {
    final id = await insertTask(
      title: '每日任务',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    // 完成"上海 8/11 的实例"（传入带时分的 8/11 05:00 = UTC 8/10 21:00）
    await db.completeInstance(
      id,
      AppClock.at(2026, 8, 11, 5, 0),
    );
    final comps = await db.allCompletionsForBackup();
    final comp = comps.single;
    expect(
      comp.instanceDate.millisecondsSinceEpoch,
      DateTime.utc(2026, 8, 10, 16, 0).millisecondsSinceEpoch,
      reason: 'P1-2：完成记录归一化为应用时区 00:00（上海 8/11 00:00 = UTC 8/10 16:00）',
    );
    expect(
      await db.isInstanceCompleted(id, AppClock.at(2026, 8, 11)),
      isTrue,
      reason: 'P1-2：按应用时区日期查询命中',
    );
  });

  test('日历按天索引：完成状态 key 按应用时区日期', () async {
    final id = await insertTask(
      title: '每日任务',
      start: AppClock.at(2026, 8, 10, 9, 0),
      rrule: 'FREQ=DAILY',
    );
    await db.completeInstance(id, AppClock.at(2026, 8, 11));
    // 上海 8/11 的完成记录，用系统时区（UTC）8/10 16:00 查询应命中
    final items = await db.getCalendarItems(
      AppClock.at(2026, 8, 1),
      AppClock.at(2026, 8, 31),
    );
    final aug11 = items.where((i) =>
        AppClock.asApp(i.instanceDate).month == 8 &&
        AppClock.asApp(i.instanceDate).day == 11);
    expect(aug11.length, 1, reason: 'P1-2：上海 8/11 有一个实例');
    expect(aug11.first.completed, isTrue,
        reason: 'P1-2：上海 8/11 实例完成状态正确');
  });
}
