import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/task/providers.dart';

import '../support/fake_notification_scheduler.dart';

/// 四象限：象限归属更新与未分类任务语义
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    // 控制器初始化/更新任务会触发提醒调度，注入替身避免平台异常
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(ProviderContainer container) async {
    final state = container.read(tasksControllerProvider);
    var guard = 0;
    while (state.loading && guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<int> insertTask({required String title, int quadrant = 4}) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      quadrant: Value(quadrant),
      createdAt: DateTime.now(),
    ));
  }

  test('默认未分类任务（quadrant=4）不属于任何象限', () async {
    final id = await insertTask(title: '未分类任务');
    final t = (await db.getTask(id))!;
    expect(t.quadrant, 4, reason: '默认任务未分类');
    // 四象限分组逻辑：quadrant 4 不应落入 0-3 任一格
    expect(t.quadrant >= 0 && t.quadrant <= 3, isFalse,
        reason: '未分类任务不进四象限格子');
  });

  test('拖入象限：updateTaskFields(quadrant) 更新归属', () async {
    await db.ensureDefaultList();
    final container = makeContainer();
    final notifier = container.read(tasksControllerProvider.notifier);
    await settle(container);

    final id = await insertTask(title: '重要任务');
    await settle(container);

    // 模拟拖入"重要紧急"（象限 0）
    await notifier.updateTaskFields(
      id,
      const TasksCompanion(quadrant: Value(0)),
    );
    await settle(container);
    final t = (await db.getTask(id))!;
    expect(t.quadrant, 0, reason: '拖入重要紧急后归属更新');

    // 再拖到"一般"（象限 3）
    await notifier.updateTaskFields(
      id,
      const TasksCompanion(quadrant: Value(3)),
    );
    await settle(container);
    final t2 = (await db.getTask(id))!;
    expect(t2.quadrant, 3, reason: '再次拖动更新象限');
  });

  test('四象限任务按象限归类查询', () async {
    await insertTask(title: '紧急任务', quadrant: 0);
    await insertTask(title: '重要不紧急', quadrant: 1);
    await insertTask(title: '一般任务', quadrant: 3);
    await insertTask(title: '未分类');

    // 从 DB 取全部任务，验证 0-3 象限分组与未分类集合
    final all = await db.getAllUncompleted();
    final cells = <int, List<Task>>{for (var i = 0; i < 4; i++) i: []};
    final unclassified = <Task>[];
    for (final t in all) {
      if (t.quadrant < 0 || t.quadrant > 3) {
        unclassified.add(t);
      } else {
        cells[t.quadrant]!.add(t);
      }
    }
    expect(cells[0]!.single.title, '紧急任务');
    expect(cells[1]!.single.title, '重要不紧急');
    expect(cells[3]!.single.title, '一般任务');
    expect(unclassified.single.title, '未分类',
        reason: '未分类任务单独计数，不落入象限');
  });
}
