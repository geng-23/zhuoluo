import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';

/// 修复回归测试：
/// - #1 通知 ID 含实例日期维度：同 (task, reminder) 不同实例互不覆盖
/// - #3 例外改期：新日期可见、原日期隐藏
/// - #6 系列改期保留过去命中的完成记录
/// - #9 计划数统计含重复任务实例
void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
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
    final taskId = 3;
    final reminderId = 1;
    final day1 = DateTime(2026, 8, 10);
    final day2 = DateTime(2026, 8, 11);
    final id1 = NotificationIds.forReminder(taskId, reminderId, day1);
    final id2 = NotificationIds.forReminder(taskId, reminderId, day2);
    expect(id1, isNot(id2), reason: '不同实例的通知 ID 必须不同，否则互相覆盖');

    // 同实例、同任务、不同提醒 ID 也互异
    final id3 = NotificationIds.forReminder(taskId, 2, day1);
    expect(id1, isNot(id3));

    // 不同任务同一天不冲突
    expect(
      NotificationIds.forReminder(4, 1, day1),
      isNot(NotificationIds.forReminder(3, 1, day1)),
    );

    // 实例日期带时间与 00:00 归一化后 ID 一致（排期/取消同基准）
    final id4 = NotificationIds.forReminder(
      taskId,
      reminderId,
      DateTime(2026, 8, 10, 23, 59),
    );
    expect(id1, id4);
  });

  test('#1 习惯通知 ID 与任务通知 ID 区段分离（常见 taskId 范围）', () {
    for (var taskId = 1; taskId <= 1500; taskId++) {
      for (var habitId = 1; habitId <= 500; habitId++) {
        final taskIdMax = NotificationIds.forReminder(
          taskId,
          10,
          DateTime(2050, 12, 31),
        );
        final habitIdMin = NotificationIds.forHabit(habitId);
        expect(
          taskIdMax,
          lessThan(habitIdMin),
          reason: 'taskId=$taskId 撞习惯区段 habitId=$habitId',
        );
      }
    }
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

  test('P0-6 通知 ID 无碰撞：同任务多条提醒跨实例、同实例均互异', () {
    final day1 = DateTime(2026, 8, 10);
    final day2 = DateTime(2026, 8, 11);
    // 同任务两条提醒 reminderId 差 1（旧公式在此场景跨实例碰撞的临界形态）
    final a = NotificationIds.forReminder(7, 1, day1);
    final b = NotificationIds.forReminder(7, 2, day1);
    expect(a, isNot(b), reason: '同实例不同提醒必须互异');
    expect(
      NotificationIds.forReminder(7, 1, day2),
      isNot(NotificationIds.forReminder(7, 2, day2)),
      reason: '相邻实例日两条提醒组合必须互异',
    );
    expect(
      NotificationIds.forReminder(7, 2, day1),
      isNot(NotificationIds.forReminder(7, 1, day2)),
      reason: '提醒 r=2 的 day1 与提醒 r=1 的 day2 不得跨实例碰撞（旧公式缺陷）',
    );
    // 同实例、同任务 63 条提醒全部互异（段位上限内）
    final ids = {
      for (var r = 0; r < 64; r++)
        NotificationIds.forReminder(7, r, day1),
    };
    expect(ids.length, 64, reason: '同实例提醒 id 段位内必须全部唯一');
  });

  test('P0-7 测试通知 ID 不与第 10 个习惯提醒 ID 碰撞', () {
    expect(
      NotificationIds.forTest,
      isNot(NotificationIds.forHabit(10)),
      reason: '旧公式 2099999990 与 forHabit(10) 相同，互相覆盖',
    );
    expect(NotificationIds.forTest, greaterThan(2100000000));
  });

  test('N-P1-1 权限缓存刷新在测试环境不抛异常且返回 true', () async {
    final svc = NotificationService.instance;
    final granted = await svc.refreshPermissionCache();
    expect(granted, isTrue,
        reason: '测试环境无原生宿主，权限查询应兜底返回 true');
  });
}
