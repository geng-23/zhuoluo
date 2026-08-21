import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// nextInstanceFor：改期本次（例外）后下一次实例的返回语义
/// - 改期到非规则日 → 返回例外目标日（传导）
/// - 改期目标日被跳过 → 跳过该日（不显示矛盾的"下次 X"）
void main() {
  late AppDatabase db;
  final today = AppClock.at(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 冻结"今天"到 2026-08-18（夹具周的周二）：
    // 第三用例夹具为"本周一 8-17 改期到本周三 8-19"，nextInstanceFor 只返回
    // ≥ 今天的实例——真实时钟越过 8-19 后该用例必失败（此前随系统时钟前进
    // 8-20+ 后持续红）；冻结后与真实日期解耦，永久稳定。
    AppClock.setNow(DateTime(2026, 8, 18, 10, 0));
  });

  tearDown(() async {
    AppClock.setNow(null);
    await db.close();
  });

  Future<TasksController> controller() async {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final c = container.read(tasksControllerProvider.notifier);
    // init 是 fire-and-forget：显式 await，避免与 tearDown 关闭 db 竞争
    await c.init();
    return c;
  }

  test('改期本次到非规则日后，下次实例返回例外目标日', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final day = today;
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每日任务',
      planStart: Value(day),
      planEnd: Value(day.add(const Duration(hours: 1))),
      rrule: const Value('FREQ=DAILY'),
      createdAt: AppClock.now(),
    ));
    final task = (await db.getTask(id))!;
    await db.insertException(TaskExceptionsCompanion.insert(
      taskId: id,
      instanceDate: day,
      action: const Value('edit'),
      overrideScheduledDate: Value(day.add(const Duration(days: 1, hours: 15))),
    ));
    final next = await controller().then((c) => c.nextInstanceFor(task));
    expect(next, isNotNull);
    expect(
      DateUtilsEx.sameDay(next!, day.add(const Duration(days: 1))),
      isTrue,
      reason: '改期到明天后，下一次实例返回例外目标日（明天）',
    );
  });

  test('改期目标日被跳过 → nextInstanceFor 不返回该目标（跳过优先）', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final day = today;
    final tomorrow = day.add(const Duration(days: 1));
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每日任务',
      planStart: Value(day),
      planEnd: Value(day.add(const Duration(hours: 1))),
      rrule: const Value('FREQ=DAILY'),
      createdAt: AppClock.now(),
    ));
    await db.insertException(TaskExceptionsCompanion.insert(
      taskId: id,
      instanceDate: day,
      action: const Value('edit'),
      overrideScheduledDate: Value(tomorrow),
    ));
    // 目标日（明天）被跳过
    await db.updateTask(
      id,
      TasksCompanion(
        skippedDates: Value(jsonEncode([tomorrow.toIso8601String()])),
      ),
    );
    final fresh = (await db.getTask(id))!;
    final next = await controller().then((c) => c.nextInstanceFor(fresh));
    expect(next, isNotNull);
    final nextDay = next!;
    expect(
      DateUtilsEx.sameDay(nextDay, tomorrow),
      isFalse,
      reason: '改期目标日被跳过时，下次实例应跳过该日（不显示矛盾的"下次 X"）',
    );
    // DAILY 下一未完成规则实例 = 后天
    expect(
      DateUtilsEx.sameDay(nextDay, day.add(const Duration(days: 2))),
      isTrue,
    );
  });

  test('中间实例改期到非规则日 → nextInstanceFor 返回改期目标日（传导）', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    // 每周一任务：本周一（8-17）改期到本周三（8-19，非规则日）
    final monday = AppClock.at(2026, 8, 17);
    final wednesday = AppClock.at(2026, 8, 19);
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '周会',
      planStart: Value(monday.add(const Duration(hours: 9))),
      planEnd: Value(monday.add(const Duration(hours: 10))),
      rrule: const Value('FREQ=WEEKLY;BYDAY=MO'),
      createdAt: AppClock.now(),
    ));
    final task = (await db.getTask(id))!;
    await db.insertException(TaskExceptionsCompanion.insert(
      taskId: id,
      instanceDate: monday,
      action: const Value('edit'),
      overrideScheduledDate: Value(wednesday),
    ));
    final next = await controller().then((c) => c.nextInstanceFor(task));
    expect(next, isNotNull);
    expect(
      DateUtilsEx.sameDay(next!, wednesday),
      isTrue,
      reason: '改期中间实例（本周一→本周三），下次实例返回改期目标日（传导到任务页）',
    );
  });
}
