import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';

/// 重复任务完成命中校验——completeInstanceIfHit 只允许在
/// 规则命中日/例外改期日写入完成记录，非命中日拒绝写入。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
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

  test('非命中日完成被拒绝，命中日正常写入', () async {
    // 每周一 10:00 的任务，锚点 2026-08-10（周一）
    final id = await insertTask(
      title: '周例会',
      start: DateTime(2026, 8, 10, 10, 0),
      rrule: 'FREQ=WEEKLY;BYDAY=MO',
    );
    // 周二（非命中日）→ 拒绝
    final tuesday = DateTime(2026, 8, 11);
    final ok = await db.completeInstanceIfHit(id, tuesday);
    expect(ok, isFalse, reason: '非命中日不得写入完成记录');
    expect(await db.isInstanceCompleted(id, tuesday), isFalse,
        reason: '拒绝后无残留记录');

    // 下周一（命中日）→ 正常写入
    final nextMonday = DateTime(2026, 8, 17);
    final ok2 = await db.completeInstanceIfHit(id, nextMonday);
    expect(ok2, isTrue, reason: '命中日正常完成');
    expect(await db.isInstanceCompleted(id, nextMonday), isTrue);
  });

  test('例外改期目标日可完成', () async {
    final monday = DateTime(2026, 8, 10);
    final id = await insertTask(
      title: '周例会',
      start: DateTime(2026, 8, 10, 10, 0),
      rrule: 'FREQ=WEEKLY;BYDAY=MO',
    );
    // 8/10 实例改期到 8/12（周二）：例外改期目标日视为有实例
    await db.insertException(
      TaskExceptionsCompanion.insert(
        taskId: id,
        instanceDate: monday,
        action: const Value('edit'),
        overrideScheduledDate: Value(DateTime(2026, 8, 12, 10, 0)),
      ),
    );
    final ok = await db.completeInstanceIfHit(id, DateTime(2026, 8, 12));
    expect(ok, isTrue, reason: '例外改期目标日应可完成');
    expect(await db.isInstanceCompleted(id, DateTime(2026, 8, 12)), isTrue);
  });

  test('非重复任务直接完成（不校验）', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '普通任务',
      planStart: Value(DateTime(2026, 8, 10, 9, 0)),
      createdAt: AppClock.now(),
    ));
    final ok = await db.completeInstanceIfHit(id, DateTime(2026, 8, 10));
    expect(ok, isTrue, reason: '非重复任务不受命中校验影响');
    expect((await db.getTask(id))!.completedAt, isNotNull);
  });
}
