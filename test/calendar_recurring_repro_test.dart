import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/main.dart';

/// 复现：重复任务在日历（周/月窗口）中是否可见
void main() {
  final now = DateTime.now();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertRecurring({
    required String title,
    required String rrule,
    required DateTime start,
  }) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    return db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: title,
      planStart: Value(start),
      planEnd: Value(start.add(const Duration(hours: 1))),
      rrule: Value(rrule),
      createdAt: now,
    ));
  }

  test('每周五重复任务应在 8/10-8/16 窗口内显示（8/14 周五）', () async {
    await insertRecurring(
      title: '每周五任务',
      rrule: 'FREQ=WEEKLY;BYDAY=FR',
      start: DateTime(2026, 8, 7, 20, 0), // 2026-08-07 周五
    );
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 16),
    );
    final hits = items.where((i) => i.task.title == '每周五任务').toList();
    expect(hits, isNotEmpty, reason: '重复任务实例应出现在日历窗口内');
    if (hits.isNotEmpty) {
      expect(
        hits.first.instanceDate,
        DateTime(2026, 8, 14),
        reason: '实例日期应为 8/14（周五）',
      );
    }
  });

  test('每2天重复任务：8/7 20:00 起，8/9 应命中（间隔边界）', () async {
    await insertRecurring(
      title: '每2天任务',
      rrule: 'FREQ=DAILY;INTERVAL=2',
      start: DateTime(2026, 8, 7, 20, 0),
    );
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 7),
      DateTime(2026, 8, 13),
    );
    final days = items
        .where((i) => i.task.title == '每2天任务')
        .map((i) => i.instanceDate.day)
        .toSet();
    // 实例：8/7, 8/9, 8/11, 8/13
    expect(days, {7, 9, 11, 13}, reason: '间隔2天的实例日期错位');
  });

  test('每天重复任务在周窗口内每天都显示', () async {
    await insertRecurring(
      title: '每天任务',
      rrule: 'FREQ=DAILY',
      start: DateTime(2026, 8, 3, 9, 0),
    );
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 16),
    );
    final days = items
        .where((i) => i.task.title == '每天任务')
        .map((i) => i.instanceDate.day)
        .toSet();
    expect(days, {10, 11, 12, 13, 14, 15, 16});
  });

  testWidgets('UI 链路：重复任务在日历周视图可见（创建后切日历）', (tester) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 规则命中今天（动态星期），保证周视图内必有一个实例
    const codes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '每日巡检',
      planStart: Value(today),
      planEnd: Value(today.add(const Duration(hours: 1))),
      rrule: Value('FREQ=WEEKLY;BYDAY=${codes[today.weekday - 1]}'),
      createdAt: now,
    ));

    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZhuoluoApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 切到日历 tab（默认周视图）
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    // 重复任务的实例应显示在时间轴（周视图今天列）
    expect(find.text('每日巡检'), findsWidgets,
        reason: '重复任务实例应出现在日历周视图');
  });

  test('跨天任务在覆盖的每一天都显示（周一 22:00-周二 02:00 → 两天都有）', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '跨天任务',
      planStart: Value(DateTime(2026, 8, 10, 22, 0)),
      planEnd: Value(DateTime(2026, 8, 11, 2, 0)),
      createdAt: now,
    ));
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 11),
    );
    final days = items
        .where((i) => i.task.title == '跨天任务')
        .map((i) => i.instanceDate.day)
        .toSet();
    expect(days, {10, 11}, reason: '跨天任务应在其覆盖的每一天都显示');
  });

  test('fixOrphanRecurringAnchors：锚点不命中规则时自动吸附到首个命中日', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    // 旧数据：规则是周二周三，但 planStart 是周一
    final monday = DateTime(2026, 8, 10, 9, 0);
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '错位任务',
      planStart: Value(monday),
      planEnd: Value(monday.add(const Duration(hours: 1))),
      rrule: const Value('FREQ=WEEKLY;BYDAY=TU,WE'),
      createdAt: now,
    ));
    await db.fixOrphanRecurringAnchors();
    final t = (await db.getTask(id))!;
    expect(t.planStart, DateTime(2026, 8, 11, 9, 0),
        reason: '周一锚点应吸附到规则首个命中日（周二）');
    // 完成记录/提醒不涉及：只改锚点
    expect(t.planEnd, DateTime(2026, 8, 11, 10, 0),
        reason: '吸附后保持时长');

    // 锚点已命中规则的任务不受影响
    final id2 = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '正常任务',
      planStart: Value(DateTime(2026, 8, 11, 14, 0)),
      planEnd: Value(DateTime(2026, 8, 11, 15, 0)),
      rrule: const Value('FREQ=WEEKLY;BYDAY=TU'),
      createdAt: now,
    ));
    await db.fixOrphanRecurringAnchors();
    final t2 = (await db.getTask(id2))!;
    expect(t2.planStart, DateTime(2026, 8, 11, 14, 0),
        reason: '已命中规则的锚点不应被改动');
  });

  test('A13：锚点不命中时吸附到最近命中日（含过去一侧），本周窗口立即可见', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    // 2026-08-12 是周三：创建"每周一"任务（锚点周三不命中规则）
    final wednesday = DateTime(2026, 8, 12, 9, 0);
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '周三建的周一任务',
      planStart: Value(wednesday),
      planEnd: Value(wednesday.add(const Duration(hours: 1))),
      rrule: const Value('FREQ=WEEKLY;BYDAY=MO'),
      createdAt: now,
    ));
    await db.fixOrphanRecurringAnchors();
    final t = (await db.getTask(id))!;
    // 最近命中日 = 本周一 8/10（过去 2 天），而非下周一 8/17
    expect(t.planStart, DateTime(2026, 8, 10, 9, 0),
        reason: '锚点应吸附到最近命中日（本周一，含过去一侧）');
    // 本周窗口（8/10 周一 ~ 8/16 周日）内应能显示实例
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 16),
    );
    final hits = items.where((i) => i.task.title == '周三建的周一任务').toList();
    expect(hits, isNotEmpty, reason: '吸附后本周窗口应有实例');
    expect(hits.first.instanceDate, DateTime(2026, 8, 10),
        reason: '实例日期为本周一');
  });

  test('A13：详情页改规则语义——周一任务改"周二周三"吸附到最近命中日（周二）', () async {
    final svc = RruleService.instance;
    final monday = DateTime(2026, 8, 10, 9, 0);
    // 锚点周一 8/10，规则 TU,WE：最近命中 = 周二 8/11（未来 1 天，比周三 8/12 近）
    final hit = svc.nearestHitOnOrNear(monday, 'FREQ=WEEKLY;BYDAY=TU,WE');
    expect(hit, DateTime(2026, 8, 11), reason: '应吸附到最近命中日周二');
    // 锚点周三 8/12，规则 MO：最近命中 = 本周一 8/10（过去 2 天，比下周一 8/17 近）
    final hit2 = svc.nearestHitOnOrNear(
      DateTime(2026, 8, 12, 9, 0),
      'FREQ=WEEKLY;BYDAY=MO',
    );
    expect(hit2, DateTime(2026, 8, 10), reason: '应吸附到本周一（过去一侧更近）');
    // 锚点本身命中 → 原地
    final hit3 = svc.nearestHitOnOrNear(
      DateTime(2026, 8, 14, 9, 0),
      'FREQ=WEEKLY;BYDAY=FR',
    );
    expect(hit3, DateTime(2026, 8, 14), reason: '命中规则的锚点原地不动');
    // COUNT 规则只向未来
    final hit4 = svc.nearestHitOnOrNear(
      DateTime(2026, 8, 12, 9, 0),
      'FREQ=WEEKLY;BYDAY=MO;COUNT=5',
    );
    expect(hit4, DateTime(2026, 8, 17), reason: 'COUNT 规则只向未来吸附');
  });

  testWidgets('UI 链路：时段重复任务在日历周视图可见（锚点命中规则）', (tester) async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const codes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
    // 带时分的重复任务：今天 09:00，规则命中今天星期
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '时段巡检',
      planStart: Value(today.add(const Duration(hours: 9))),
      planEnd: Value(today.add(const Duration(hours: 10))),
      isAllDay: const Value(false),
      rrule: Value('FREQ=WEEKLY;BYDAY=${codes[today.weekday - 1]}'),
      createdAt: now,
    ));

    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZhuoluoApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    expect(find.text('时段巡检'), findsWidgets,
        reason: '时段重复任务实例应出现在日历周视图时间轴');
  });

  test('A13-2：COUNT 规则 + 时段任务应命中当天（全天显示而时段不显示的根因）', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    // 复刻真机备份数据：DAILY;COUNT=10 时段任务，锚点 8/5 07:50
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: 'COUNT时段任务',
      planStart: Value(DateTime(2026, 8, 5, 7, 50)),
      planEnd: Value(DateTime(2026, 8, 5, 8, 50)),
      isAllDay: const Value(false),
      rrule: const Value('FREQ=DAILY;COUNT=10'),
      createdAt: now,
    ));
    // 第 3 个实例日 8/7 应命中（此前 to: date 00:00 过滤掉 07:50 实例）
    expect(
      RruleService.instance.hitsOn(
        'FREQ=DAILY;COUNT=10',
        DateTime(2026, 8, 5, 7, 50),
        DateTime(2026, 8, 7),
      ),
      isTrue,
      reason: 'COUNT 规则时段任务在实例日应命中',
    );
    // 日历窗口 8/3~8/9 内应有 8/5~8/9 五个实例（COUNT=10 从 8/5 起）
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 3),
      DateTime(2026, 8, 9),
    );
    final days = items
        .where((i) => i.task.title == 'COUNT时段任务')
        .map((i) => i.instanceDate.day)
        .toSet();
    expect(days, {5, 6, 7, 8, 9}, reason: 'COUNT 时段任务窗口内实例日期');
    // 最后一个实例（COUNT 截断）：8/14 命中、8/15 不命中
    expect(
      RruleService.instance.hitsOn(
        'FREQ=DAILY;COUNT=10',
        DateTime(2026, 8, 5, 7, 50),
        DateTime(2026, 8, 15),
      ),
      isFalse,
      reason: 'COUNT 截断后不再命中',
    );
  });

  test('A13-2：COUNT 规则时段任务锚点在未来的实例日命中', () async {
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final now = DateTime.now();
    // 复刻真机备份 id=11：锚点 8/8 10:10，DAILY;COUNT=10
    await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '未来COUNT时段',
      planStart: Value(DateTime(2026, 8, 8, 10, 10)),
      planEnd: Value(DateTime(2026, 8, 8, 11, 10)),
      isAllDay: const Value(false),
      rrule: const Value('FREQ=DAILY;COUNT=10'),
      createdAt: now,
    ));
    // 8/8（首个实例日）应命中
    expect(
      RruleService.instance.hitsOn(
        'FREQ=DAILY;COUNT=10',
        DateTime(2026, 8, 8, 10, 10),
        DateTime(2026, 8, 8),
      ),
      isTrue,
      reason: '首个实例日应命中',
    );
    final items = await db.getCalendarItems(
      DateTime(2026, 8, 3),
      DateTime(2026, 8, 9),
    );
    final days = items
        .where((i) => i.task.title == '未来COUNT时段')
        .map((i) => i.instanceDate.day)
        .toSet();
    expect(days, {8, 9}, reason: '未来开始的 COUNT 时段任务窗口内实例日期');
  });

  test('P1-16：全天系列拖动改期后撤销恢复 isAllDay', () async {
    SoundService.enabled = false;
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(calendarControllerProvider.notifier);
    await db.ensureDefaultList();
    final list = await db.getDefaultList();
    final id = await db.insertTask(TasksCompanion.insert(
      listId: list.id,
      title: '全天系列',
      isAllDay: const Value(true),
      planStart: Value(DateTime(2026, 8, 10)),
      planEnd: Value(DateTime(2026, 8, 11)),
      rrule: const Value('FREQ=WEEKLY;BYDAY=MO'),
      createdAt: now,
    ));

    // 系列拖动改期到 8/12 09:00（拖动进时间轴 → 非全天；
    // 全天任务时长 1 天，C5-1 回退：09:00+1天 > 23:00 → 8/11 23:00）
    await notifier.moveTaskToDateTimeSeries(id, DateTime(2026, 8, 12, 9, 0));
    var t = (await db.getTask(id))!;
    expect(t.isAllDay, isFalse, reason: '拖动改期后为时段任务');
    expect(t.planStart, DateTime(2026, 8, 11, 23, 0),
        reason: 'C5-1：时长 1 天不跨午夜，回退到 23:00 前');

    // 撤销 → 恢复原计划时间与全天状态
    await notifier.undoMoveTaskSeries();
    t = (await db.getTask(id))!;
    expect(t.isAllDay, isTrue,
        reason: 'P1-16：撤销系列改期必须恢复全天状态（此前变成时段任务）');
    expect(t.planStart, DateTime(2026, 8, 10));
    // drain：等待 dataVersion 监听触发的异步刷新完成（避免 db 关闭后仍在用）
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
}
