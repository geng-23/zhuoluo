import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// 搜索功能回归测试（搜索后切换视图不再卡在搜索结果）
void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTask({
    required String title,
    String note = '',
    DateTime? planStart,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final start = planStart;
    return db.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: title,
        note: Value(note),
        planStart: Value(start),
        // 带计划开始的任务需有 planEnd 才会命中"今天"窗口（与正常创建一致）
        planEnd: Value(
          start?.add(const Duration(hours: 1)),
        ),
        createdAt: now,
      ),
    );
  }

  Future<ProviderContainer> makeContainer() async {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    var guard = 0;
    while (container.read(tasksControllerProvider).loading && guard < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard++;
    }
    return container;
  }

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  test('搜索后切换智能视图：searchQuery 清空且显示目标视图任务', () async {
    final container = await makeContainer();
    final notifier = container.read(tasksControllerProvider.notifier);
    final todayTask = await insertTask(title: '今天报告', planStart: today);
    final otherTask = await insertTask(title: '其他任务');

    notifier.search('报告');
    await drain();
    expect(container.read(tasksControllerProvider).searchQuery, '报告');
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      contains(todayTask),
    );

    // 核心修复：切到"今天"后不再卡在搜索结果
    notifier.selectSmartView('today');
    await drain();
    expect(container.read(tasksControllerProvider).searchQuery, isEmpty,
        reason: '搜索修复：切换视图必须清空搜索词');
    expect(container.read(tasksControllerProvider).smartView, 'today');
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      contains(todayTask),
    );
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      isNot(contains(otherTask)),
      reason: '"今天"视图只显示今天计划的任务',
    );
  });

  test('搜索后切换清单视图：searchQuery 清空且显示清单任务', () async {
    final container = await makeContainer();
    final notifier = container.read(tasksControllerProvider.notifier);
    final listId = await notifier.createList('工作', '#E53935');
    await drain();
    final inList = await (() async {
      final id = await db.insertTask(TasksCompanion.insert(
        listId: listId,
        title: '工作项',
        createdAt: now,
      ));
      return id;
    })();
    await insertTask(title: '收件箱项');

    notifier.search('工作');
    await drain();
    expect(container.read(tasksControllerProvider).searchQuery, '工作');

    notifier.selectList(listId);
    await drain();
    expect(container.read(tasksControllerProvider).searchQuery, isEmpty,
        reason: '搜索修复：切清单视图同样清空搜索词');
    expect(container.read(tasksControllerProvider).smartView, 'list');
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      contains(inList),
    );
  });

  test('clearSearch 回到"全部"视图', () async {
    final container = await makeContainer();
    final notifier = container.read(tasksControllerProvider.notifier);
    await insertTask(title: '测试任务');

    notifier.search('测试');
    await drain();
    notifier.clearSearch();
    await drain();
    expect(container.read(tasksControllerProvider).searchQuery, isEmpty);
    expect(container.read(tasksControllerProvider).smartView, 'all');
    expect(container.read(tasksControllerProvider).tasks, hasLength(1));
  });

  test('搜索后再次搜索可更新结果（实时搜索语义）', () async {
    final container = await makeContainer();
    final notifier = container.read(tasksControllerProvider.notifier);
    final a = await insertTask(title: '苹果');
    final b = await insertTask(title: '香蕉');

    notifier.search('苹果');
    await drain();
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      contains(a),
    );

    notifier.search('香蕉');
    await drain();
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      contains(b),
    );
    expect(
      container.read(tasksControllerProvider).tasks.map((t) => t.id),
      isNot(contains(a)),
    );
  });
}
