import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// nextInstanceFor：改期本次（例外）后，下一次实例返回例外目标日
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('改期本次到非规则日后，下次实例返回例外目标日', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final today = AppClock.at(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每日任务',
      planStart: Value(today),
      planEnd: Value(today.add(const Duration(hours: 1))),
      rrule: const Value('FREQ=DAILY'),
      createdAt: AppClock.now(),
    ));
    final task = (await db.getTask(id))!;
    await db.insertException(TaskExceptionsCompanion.insert(
      taskId: id,
      instanceDate: today,
      action: const Value('edit'),
      overrideScheduledDate: Value(today.add(const Duration(days: 1, hours: 15))),
    ));
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final controller = container.read(tasksControllerProvider.notifier);
    // init 是 fire-and-forget：显式 await，避免与 tearDown 关闭 db 竞争
    await controller.init();
    final next = await controller.nextInstanceFor(task);
    expect(next, isNotNull);
    expect(
      DateUtilsEx.sameDay(next!, today.add(const Duration(days: 1))),
      isTrue,
      reason: '改期到明天后，下一次实例返回例外目标日（明天）',
    );
  });
}
