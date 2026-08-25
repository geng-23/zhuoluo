import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';

import '../support/fake_notification_scheduler.dart';

/// 习惯打卡通知补丁与全窗口排期回归测试：
/// - 打卡后仅取消今天的习惯提醒（未来日期的已排通知不受影响）
/// - 撤销后今日提醒时刻未过则补排今天一条，已过则不排
/// - 无提醒时间的习惯打卡不做任何通知操作
/// - 快速「打卡→撤销」经每习惯队列串行执行，最终状态一致
/// - 全窗口排期批量预取：已打卡日期跳过、今日已过时刻跳过
void main() {
  // 固定"今天"=2026-08-20 10:00，保证跨午夜/任意系统时区下断言一致
  final now = DateTime(2026, 8, 20, 10, 0);
  final today = DateTime(2026, 8, 20);

  late AppDatabase db;
  late ReminderScheduler scheduler;
  late FakeNotificationScheduler fake;

  setUp(() {
    AppClock.setNow(now);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    scheduler = ReminderScheduler(db);
    fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    AppClock.setNow(null);
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<int> seedHabit({DateTime? reminderTime}) =>
      db.insertHabit('阅读', '📚', reminderTime);

  int todayId(int habitId) => NotificationIds.forHabit(habitId, today);

  test('打卡后仅取消今天的提醒通知，未来日期的已排通知不受影响', () async {
    final id = await seedHabit(reminderTime: DateTime(2026, 8, 20, 9));
    final habit = (await db.getHabit(id))!;
    // 先全窗口排期建立基线（今日 09:00 已过，从明天起共 92 条）
    await scheduler.scheduleHabitReminder(habit);
    expect(fake.scheduled.length, 92);

    // 打卡：只应出现一条取消（今天），不再有任何调度/其他取消
    fake.clear();
    await scheduler.onHabitToggled(habit, done: true);
    expect(fake.cancelled, [todayId(id)]);
    expect(fake.scheduled, isEmpty);
  });

  test('撤销打卡且今日时刻未过时补排今天一条', () async {
    final id = await seedHabit(reminderTime: DateTime(2026, 8, 20, 11));
    final habit = (await db.getHabit(id))!;
    await scheduler.onHabitToggled(habit, done: false);
    expect(fake.cancelled, isEmpty);
    expect(fake.scheduled.length, 1);
    expect(fake.scheduled.first.id, todayId(id));
    expect(fake.scheduled.first.when.hour, 11);
    expect(
      fake.scheduled.first.channel,
      NotificationService.habitReminderChannelId,
    );
  });

  test('撤销打卡但今日时刻已过时不排', () async {
    final id = await seedHabit(reminderTime: DateTime(2026, 8, 20, 9));
    final habit = (await db.getHabit(id))!;
    await scheduler.onHabitToggled(habit, done: false);
    expect(fake.scheduled, isEmpty);
    expect(fake.cancelled, isEmpty);
  });

  test('无提醒时间的习惯打卡/撤销不做任何通知操作', () async {
    final id = await seedHabit();
    final habit = (await db.getHabit(id))!;
    await scheduler.onHabitToggled(habit, done: true);
    await scheduler.onHabitToggled(habit, done: false);
    expect(fake.scheduled, isEmpty);
    expect(fake.cancelled, isEmpty);
  });

  test('快速「打卡→撤销」串行执行：取消在前、补排在后，最终恢复提醒', () async {
    final id = await seedHabit(reminderTime: DateTime(2026, 8, 20, 11));
    final habit = (await db.getHabit(id))!;
    // 不等前序完成即发起下一次，模拟快速连点——队列保证顺序
    final f1 = scheduler.onHabitToggled(habit, done: true);
    final f2 = scheduler.onHabitToggled(habit, done: false);
    await Future.wait([f1, f2]);
    expect(fake.cancelled, [todayId(id)]);
    expect(fake.scheduled.map((s) => s.id), [todayId(id)]);
  });

  test('全窗口排期：已打卡日期跳过、今日已过时刻跳过（批量预取口径）', () async {
    final id = await seedHabit(reminderTime: DateTime(2026, 8, 20, 9));
    final habit = (await db.getHabit(id))!;
    // 预置两天已打卡
    await db.insertHabitRecordFull(
      HabitRecordsCompanion.insert(
        habitId: id,
        date: DateTime(2026, 8, 22),
        completedAt: now,
      ),
    );
    await db.insertHabitRecordFull(
      HabitRecordsCompanion.insert(
        habitId: id,
        date: DateTime(2026, 8, 25),
        completedAt: now,
      ),
    );

    await scheduler.scheduleHabitReminder(habit);
    // 窗口 93 天：今日时刻已过跳过（1）+ 已打卡跳过（2）→ 90 条，
    // 覆盖明天 8/21 至 11/20
    expect(fake.scheduled.length, 90);
    final whens = fake.scheduled.map((s) => s.when).toList();
    bool hasDay(int m, int d) =>
        whens.any((w) => w.year == 2026 && w.month == m && w.day == d);
    expect(hasDay(8, 20), isFalse, reason: '今日时刻已过不排');
    expect(hasDay(8, 22), isFalse, reason: '已打卡日不排');
    expect(hasDay(8, 25), isFalse, reason: '已打卡日不排');
    expect(hasDay(8, 21), isTrue, reason: '明天正常排');
    expect(hasDay(11, 20), isTrue, reason: '窗口末天正常排');
    for (final w in whens) {
      expect(w.hour, 9, reason: '全部按提醒时刻 09:00 排');
    }
  });

  test('取消窗口：93 天逐日全部取消且 ID 互异', () async {
    final id = await seedHabit(reminderTime: DateTime(2026, 8, 20, 9));
    await scheduler.cancelHabitReminder(id);
    expect(fake.cancelled.length, 93);
    expect(fake.cancelled.toSet().length, 93);
    expect(fake.cancelled, contains(todayId(id)));
  });
}
