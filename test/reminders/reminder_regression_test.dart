import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';

import '../support/fake_notification_scheduler.dart';

/// 修复回归测试：
/// - #1 通知 ID 含实例日期维度：同 (task, reminder) 不同实例互不覆盖
/// - #3 例外改期：新日期可见、原日期隐藏
/// - #6 系列改期保留过去命中的完成记录
/// - #9 计划数统计含重复任务实例
void main() {
  // 固定基准日期（真实"今天"会让月初/深夜运行的测试间歇失败：
  // #6 用例从当月 1 号逐日完成，断言记录数 >5，每月 1-5 日仅 1-5 条必挂）
  final now = DateTime(2026, 8, 20, 10, 0);
  final today = DateTime(2026, 8, 20);

  late AppDatabase db;

  setUp(() {
    // 调度器内部用 AppClock.now() 计算 93 天窗口，注入固定时钟保证
    // 跨午夜/任意系统时区下排期窗口与断言一致
    AppClock.setNow(now);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 调度路径注入替身（重排/取消提醒走记录型替身，不触平台插件）
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    AppClock.setNow(null);
    NotificationService.instance.debugOverrideScheduler = null;
    NotificationService.instance.debugOverridePermission = null;
    await db.close();
  });

  Future<int> seedRecurringTask(String rrule, {DateTime? start}) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: 'r',
      rrule: Value(rrule),
      planStart: Value(start ?? DateTime(now.year, now.month, now.day, 9)),
      createdAt: now,
    ));
  }

  test('#1 通知 ID 含实例日期维度：同一 (task, reminder) 不同实例 ID 互异', () {
    final reminderId = 1;
    final day1 = DateTime(2026, 8, 10);
    final day2 = DateTime(2026, 8, 11);
    final id1 = NotificationIds.forReminder(reminderId, day1);
    final id2 = NotificationIds.forReminder(reminderId, day2);
    expect(id1, isNot(id2), reason: '不同实例的通知 ID 必须不同，否则互相覆盖');

    // 同实例、同任务、不同提醒 ID 也互异
    final id3 = NotificationIds.forReminder(2, day1);
    expect(id1, isNot(id3));

    // 不同任务不冲突：提醒 ID 是 Reminders 表全局自增主键，不同任务的提醒
    // 必然不同 ID（此处以不同 reminderId 模拟两条不同任务的提醒记录）
    expect(
      NotificationIds.forReminder(1, day1),
      isNot(NotificationIds.forReminder(2, day1)),
    );

    // 实例日期带时间与 00:00 归一化后 ID 一致（排期/取消同基准）
    final id4 = NotificationIds.forReminder(
      reminderId,
      DateTime(2026, 8, 10, 23, 59),
    );
    expect(id1, id4);
  });

  test('#1 提醒通知 ID 与习惯通知 ID 区段分离（大 reminderId 范围）', () {
    // reminderId 为全局自增主键，验证累积到远超 64 仍安全
    for (var reminderId = 1; reminderId <= 100000; reminderId += 997) {
      final reminderIdMax = NotificationIds.forReminder(
        reminderId,
        DateTime(2050, 12, 31),
      );
      final habitIdMin = NotificationIds.forHabit(1, DateTime(2024, 1, 1));
      expect(
        reminderIdMax,
        lessThan(habitIdMin),
        reason: 'reminderId=$reminderId 撞习惯区段',
      );
    }
    // 上限内最高值不超 int32（Android 通知 ID 为 32 位有符号）
    expect(
      NotificationIds.forReminder(127999, DateTime(2068, 12, 31)),
      lessThan(2147483647),
    );
  });

  test('#3 例外改期后实例在新日期可见、原日期隐藏', () async {
    // 周一重复任务
    final monday2026 = DateTime(2026, 8, 10); // 2026-08-10 是周一
    final taskId = await seedRecurringTask(
      'FREQ=WEEKLY;BYDAY=MO',
      start: monday2026,
    );
    final task = (await db.getTask(taskId))!;

    // 改期：8/10 → 8/12（周三）
    await db.insertException(
      TaskExceptionsCompanion.insert(
        taskId: taskId,
        instanceDate: monday2026,
        action: const Value('edit'),
        overrideScheduledDate: Value(DateTime(2026, 8, 12)),
      ),
    );

    // 原日期 8/10 不再显示
    expect(await db.expandTaskForDate(task, monday2026), isEmpty,
        reason: '被改期的原日期不应再显示实例');
    // 新日期 8/12 显示
    expect(
      (await db.expandTaskForDate(task, DateTime(2026, 8, 12))).length,
      1,
      reason: '改期后的新日期应显示实例',
    );
    // 其他规则日期（8/17）仍正常
    expect(
      (await db.expandTaskForDate(task, DateTime(2026, 8, 17))).length,
      1,
    );
  });

  test('#3 delete 例外：原日期隐藏', () async {
    final monday2026 = DateTime(2026, 8, 10);
    final taskId = await seedRecurringTask(
      'FREQ=WEEKLY;BYDAY=MO',
      start: monday2026,
    );
    final task = (await db.getTask(taskId))!;
    await db.insertException(
      TaskExceptionsCompanion.insert(
        taskId: taskId,
        instanceDate: monday2026,
        action: const Value('delete'),
      ),
    );
    expect(await db.expandTaskForDate(task, monday2026), isEmpty);
    expect(
      (await db.expandTaskForDate(task, DateTime(2026, 8, 17))).length,
      1,
    );
  });

  test('#6 系列改期保留过去命中的完成记录', () async {
    final start = DateTime(now.year, now.month, 1);
    final taskId = await seedRecurringTask('FREQ=DAILY', start: start);
    // 连续完成 20 天（含 >3 个月前之外……用 20 天过去记录模拟历史）
    for (var i = 0; i < 20; i++) {
      final d = start.add(Duration(days: i));
      if (!d.isAfter(today)) {
        await db.completeInstance(taskId, d);
      }
    }
    final before = await db.allCompletionsForBackup();
    expect(before.where((c) => c.taskId == taskId).length, greaterThan(5));

    // 系列改期到 30 天前：新系列从过去开始，过去 7 天的完成记录命中新规则 → 保留
    final newStart = today.subtract(const Duration(days: 30));
    final removed = await db.pruneCompletionsForTask(
      taskId,
      newStart,
      'FREQ=DAILY',
    );
    final after = await db.allCompletionsForBackup();
    expect(removed, isEmpty,
        reason: '新规则仍命中过去的日期，完成记录不应被清理');
    expect(
      after.where((c) => c.taskId == taskId).length,
      before.where((c) => c.taskId == taskId).length,
    );
  });

  test('#9 计划数统计包含重复任务实例（按窗口展开）', () async {
    final start = DateTime(now.year, now.month, 1);
    await seedRecurringTask('FREQ=DAILY', start: start);
    final from = DateTime(now.year, now.month, 10);
    final to = DateTime(now.year, now.month, 12);
    final planned = await db.getPlannedCountByDay(from, to);
    // 每天 1 个实例 → 3 天共 3 项
    var total = 0;
    planned.forEach((_, v) => total += v);
    expect(total, 3, reason: '重复任务应按实例计入每天的计划数');
  });

  test('#9 计划数统计：dueTime-only 任务按截止日计入', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final due = DateTime(now.year, now.month, 15, 18, 0);
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: 'due-only',
      dueTime: Value(due),
      createdAt: now,
    ));
    final planned = await db.getPlannedCountByDay(
      DateTime(now.year, now.month, 10),
      DateTime(now.year, now.month, 20),
    );
    expect(planned[DateTime(now.year, now.month, 15)], 1,
        reason: '仅有截止时间的任务应按截止日计入计划数');
  });

  test('通知 ID 无碰撞：同任务多条提醒跨实例、同实例均互异', () {
    final day1 = DateTime(2026, 8, 10);
    final day2 = DateTime(2026, 8, 11);
    // 同任务两条提醒 reminderId 差 1（旧公式在此场景跨实例碰撞的临界形态）
    final a = NotificationIds.forReminder(1, day1);
    final b = NotificationIds.forReminder(2, day1);
    expect(a, isNot(b), reason: '同实例不同提醒必须互异');
    expect(
      NotificationIds.forReminder(1, day2),
      isNot(NotificationIds.forReminder(2, day2)),
      reason: '相邻实例日两条提醒组合必须互异',
    );
    expect(
      NotificationIds.forReminder(2, day1),
      isNot(NotificationIds.forReminder(1, day2)),
      reason: '提醒 r=2 的 day1 与提醒 r=1 的 day2 不得跨实例碰撞（旧公式缺陷）',
    );
    // 同实例、同任务 64 条提醒全部互异（旧段位上限内）
    final ids = {
      for (var r = 0; r < 64; r++) NotificationIds.forReminder(r, day1),
    };
    expect(ids.length, 64, reason: '同实例提醒 id 段位内必须全部唯一');
  });

  test('提醒自增 ID 累积远超 64 仍无碰撞（修复回归）', () {
    final day1 = DateTime(2026, 8, 10);
    final day2 = DateTime(2026, 8, 11);
    final day3 = DateTime(2026, 8, 12);
    // 全局提醒记录自增累积形态：r.id 跨任务单调递增，64/100/10000 均为现实可达
    for (final r in [64, 65, 100, 999, 10000]) {
      // 与相邻 ID 的提醒跨实例不碰撞（旧公式 r.id=64 与 r.id=0 跨日同 ID）
      expect(
        NotificationIds.forReminder(r, day1),
        isNot(NotificationIds.forReminder(0, day2)),
        reason: 'reminderId=$r 的 day1 不得与 reminderId=0 的 day2 同 ID',
      );
      expect(
        NotificationIds.forReminder(r, day1),
        isNot(NotificationIds.forReminder(r - 64 < 0 ? 0 : r - 64, day2)),
      );
      // 同 reminderId 不同实例仍互异
      expect(
        NotificationIds.forReminder(r, day1),
        isNot(NotificationIds.forReminder(r, day2)),
      );
      // 同实例不同 reminderId 仍互异
      expect(
        NotificationIds.forReminder(r, day3),
        isNot(NotificationIds.forReminder(r + 1, day3)),
      );
    }
  });

  test('测试通知 ID 不与第 10 个习惯提醒 ID 碰撞', () {
    expect(
      NotificationIds.forTest,
      isNot(NotificationIds.forHabit(10, DateTime(2050, 12, 31))),
      reason: '旧公式 2099999990 与 forHabit(10) 相同，互相覆盖',
    );
    expect(NotificationIds.forTest, greaterThan(2100000000));
  });

  test('权限缓存刷新在无平台宿主时不抛异常且返回 true', () async {
    // 清空替身：验证真实容错路径（平台插件未初始化时吞异常兜底 true）
    NotificationService.instance.debugOverrideScheduler = null;
    final svc = NotificationService.instance;
    final granted = await svc.refreshPermissionCache();
    expect(granted, isTrue,
        reason: '测试环境无原生宿主，权限查询应兜底返回 true');
  });

  test('reloadSystemTimezone 无原生宿主时静默返回 false（不抛异常）', () async {
    // 测试环境无 'zhuoluo/notifications' 原生通道：invokeMethod 抛
    // MissingPluginException，必须被捕获并返回 false（不触发重排）
    final changed = await NotificationService.instance.reloadSystemTimezone();
    expect(changed, isFalse);
  });

  test('习惯提醒 ID 含日期维度且段位不碰撞', () {
    final day1 = DateTime(2026, 8, 10);
    final day2 = DateTime(2026, 8, 11);
    expect(
      NotificationIds.forHabit(1, day1),
      isNot(NotificationIds.forHabit(1, day2)),
      reason: '逐日排期后同习惯不同日期 ID 必须不同（按天跳过打卡）',
    );
    expect(
      NotificationIds.forHabit(1, day1),
      isNot(NotificationIds.forHabit(2, day1)),
      reason: '不同习惯不碰撞',
    );
    // 段位：远低于测试段（int32 上限），高于任务提醒段
    final maxHabit = NotificationIds.forHabit(1, DateTime(2050, 12, 31));
    expect(maxHabit, lessThan(NotificationIds.forTest));
    expect(maxHabit, greaterThan(0));
  });

  test('测试通知 ID 不与任务/习惯区段重叠', () {
    final testId = NotificationIds.forTest;
    final habitId = NotificationIds.forHabit(1, DateTime(2050, 12, 31));
    final taskId = NotificationIds.forReminder(1, DateTime(2026, 8, 10));
    expect(testId, isNot(equals(habitId)));
    expect(testId, isNot(equals(taskId)));
    expect(testId, greaterThan(habitId),
        reason: '测试段在 int32 上限附近，高于习惯段');
  });

  test('rescheduleIfStale 未过期时短路（不重复全量重排）', () async {
    // setUp 已注入记录型替身（FakeNotificationScheduler）：
    // 断言门控逻辑（此前依赖平台插件不可用时的异常吞掉行为，
    // 属"假绿"——无法验证是否真的短路）
    final fake = NotificationService.instance.debugOverrideScheduler! as FakeNotificationScheduler;

    final scheduler = ReminderScheduler(db);
    await scheduler.rescheduleAll();
    // 全量重排：cancelAll 1 次 + 重新调度
    expect(fake.cancelAllCount, 1, reason: 'rescheduleAll 先全量取消');
    final afterFull = fake.scheduled.length;
    expect(afterFull, greaterThanOrEqualTo(0));

    // 立即调用 rescheduleIfStale（<24h）应被门控短路：不再次 cancelAll
    await scheduler.rescheduleIfStale();
    expect(fake.cancelAllCount, 1,
        reason: '<24h 门控应短路，不得二次全量重排');
    expect(fake.scheduled.length, afterFull,
        reason: '短路后不得新增调度');
  });

  test('权限未授予时 rescheduleAll 不先 cancelAll（避免清掉已排提醒）', () async {
    final fake = NotificationService.instance.debugOverrideScheduler!
        as FakeNotificationScheduler;
    // 强制权限被拒（覆盖 setUp 注入的调度替身"视为已授权"路径）
    NotificationService.instance.debugOverridePermission = false;
    addTearDown(() => NotificationService.instance.debugOverridePermission = null);
    // 让缓存确认到"被拒"状态
    await NotificationService.instance.refreshPermissionCache();

    final scheduler = ReminderScheduler(db);
    await scheduler.rescheduleAll();
    expect(fake.cancelAllCount, 0,
        reason: '权限未授予时全量重排应整体跳过，不得先清空已排提醒');
    expect(fake.scheduled, isEmpty,
        reason: '权限被拒不排新提醒（schedule 短路一致）');
  });
}
