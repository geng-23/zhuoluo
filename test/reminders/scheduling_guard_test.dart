import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';

import '../support/fake_notification_scheduler.dart';

/// 调度复杂度守护测试：
///
/// 1. 预算断言——单次用户操作允许触发的平台调用次数有上限。
///    功能测试防"做错"，预算测试防"做慢"：实例级操作若退化回
///    93 天全窗口重建（≈186 次平台往返），在此立即暴露；
/// 2. 源码门禁——features 层禁止 await 全窗重排（反馈不得阻塞在
///    通知重排上）。白名单文件须为规则编辑/例外改期/时区变化/
///    备份恢复等一次性显式场景，并在本用例中登记理由。
void main() {
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

  /// 造一个每日重复任务：今天起每天 11:00，1 条提醒（提前 0 分钟）。
  /// 今天 11:00 未过 → 窗口内今天起共 94 天可排。
  Future<Task> seedDailyTask() async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每日阅读',
      rrule: const Value('FREQ=DAILY'),
      planStart: Value(DateTime(now.year, now.month, now.day, 11)),
      createdAt: now,
    ));
    await db.insertReminder(RemindersCompanion.insert(
      taskId: id,
      remindMinutesBefore: const Value(0),
    ));
    return (await db.getTask(id))!;
  }

  test('完成实例只取消当天通知（预算 ≤2 次 RPC，无任何调度）', () async {
    final task = await seedDailyTask();
    // 建立基线：全窗口排期
    await scheduler.scheduleTask(task);

    fake.clear();
    await scheduler.onInstanceCompleted(task, today);
    expect(fake.scheduled, isEmpty, reason: '完成实例不得触发任何新调度');
    expect(fake.cancelled.length, lessThanOrEqualTo(2),
        reason: '只能取消当天通知（1 条提醒 = 1 次取消）');
    expect(
      fake.cancelled,
      contains(NotificationIds.forReminder(1, today)),
      reason: '取消的必须是当天实例的通知 ID',
    );
  });

  test('撤销实例当天时刻未过时补排当天一条；已过时不排', () async {
    final task = await seedDailyTask();

    fake.clear();
    await scheduler.onInstanceReopened(task, today);
    expect(fake.cancelled, isEmpty);
    expect(fake.scheduled.length, 1, reason: '当天 11:00 未过，补排一条');
    expect(fake.scheduled.first.id, NotificationIds.forReminder(1, today));
    expect(fake.scheduled.first.when.hour, 11);

    // 已过时刻的日期：不排（与全窗重排口径一致）
    fake.clear();
    await scheduler.onInstanceReopened(
      task,
      DateTime(2026, 8, 19),
    );
    expect(fake.scheduled, isEmpty, reason: '过去日期不得补排');
  });

  test('快速「完成→撤销」经串行链执行：取消在前、补排在后', () async {
    final task = await seedDailyTask();
    await scheduler.scheduleTask(task);
    fake.clear(); // 丢弃全窗基线记录，只观察补丁动作

    // 不等前序完成即发起下一次，模拟快速连点——补丁链保证顺序
    final f1 = scheduler.onInstanceCompleted(task, today);
    final f2 = scheduler.onInstanceReopened(task, today);
    await Future.wait([f1, f2]);
    expect(
      fake.cancelled,
      [NotificationIds.forReminder(1, today)],
      reason: '只有完成侧的一次取消',
    );
    expect(
      fake.scheduled.map((s) => s.id),
      [NotificationIds.forReminder(1, today)],
      reason: '撤销侧补排当天提醒，最终状态恢复',
    );
  });

  test('预算回归：完成+撤销一轮的总平台调用 ≤4 次（全窗重建则 >180 次）', () async {
    final task = await seedDailyTask();
    await scheduler.scheduleTask(task);
    final baselineRpc = fake.scheduled.length + fake.cancelled.length;

    fake.clear();
    await scheduler.onInstanceCompleted(task, today);
    await scheduler.onInstanceReopened(task, today);
    final toggleRpc = fake.scheduled.length + fake.cancelled.length;

    expect(toggleRpc, lessThanOrEqualTo(4),
        reason: '一轮完成/撤销不得超过 4 次平台调用');
    expect(baselineRpc, greaterThan(90),
        reason: '对照：全窗口重建确实在百次量级（证明预算有意义）');
  });

  test('features 层源码门禁：禁止 await 全窗重排', () {
    const marker = '// sched-allow:';
    const allowedFiles = <String, String>{
      'lib/features/task/providers.dart':
          '新增任务/更新字段/例外改期：显式编辑流，返回权限结果或低频一次性重建',
      'lib/features/calendar/providers.dart':
          '日历拖拽改期/规则编辑：显式编辑流的一次性重建',
      'lib/features/profile/restore_flow.dart': '备份恢复后的一次性全量重建',
      'lib/features/profile/preferences_page.dart': '时区变化后的一次性全量重建',
    };
    // 匹配 await 与重排调用跨行的情况（await ref\n .read(...)\n .scheduleTask(...)）。
    // \bawait\b 词边界：避免匹配 unawaited( 内部的 "await" 子串
    final pattern = RegExp(
      r'\bawait\b[^;{}]{0,160}?\.(scheduleTask|rescheduleAll|scheduleHabitReminder)\s*\(',
    );
    final violations = <String>[];
    final dir = Directory('lib/features');
    for (final file in dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final raw = file.readAsStringSync();
      // 去掉行注释后再匹配，避免注释里的示例代码误报
      final code = raw
          .split('\n')
          .map((l) => l.split('//').first)
          .join('\n');
      if (!pattern.hasMatch(code)) continue;
      final reason = allowedFiles[file.path];
      if (reason == null) {
        violations.add('${file.path}: 出现 await 全窗重排且未登记白名单');
      } else if (!raw.contains(marker)) {
        violations.add('${file.path}: 在白名单内但缺少 "$marker" 标记');
      }
    }
    expect(violations, isEmpty,
        reason: 'UI 反馈不得阻塞在通知重排上；确需等待请在白名单登记理由'
            '并加 $marker 标记。\n${violations.join('\n')}');
  });
}
