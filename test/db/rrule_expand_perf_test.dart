import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

/// 无限期规则性能优化回归：expand 窗口跳跃 + skippedDates Set 化。
/// 核心不变量：带 from 的"跳跃展开"结果必须与"完整展开手动过滤"完全一致。
void main() {
  final svc = RruleService.instance;
  // 模拟"创建很久的无限期任务"：start 在窗口起点 2 年前
  final start = AppClock.at(2024, 8, 10, 9, 0);
  final from = AppClock.at(2026, 8, 1);
  final to = AppClock.at(2026, 8, 31);

  group('expand 窗口跳跃（无限期规则性能优化）', () {
    test('无 COUNT 规则：跳跃展开 == 完整展开手动过滤（各 FREQ/INTERVAL）', () {
      const rules = [
        'FREQ=DAILY',
        'FREQ=DAILY;INTERVAL=3',
        'FREQ=WEEKLY',
        'FREQ=WEEKLY;BYDAY=MO,WE,FR',
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU',
        'FREQ=MONTHLY',
        'FREQ=MONTHLY;BYMONTHDAY=1,15,31',
        'FREQ=MONTHLY;INTERVAL=2',
        'FREQ=YEARLY',
        'FREQ=YEARLY;INTERVAL=2',
      ];
      for (final rrule in rules) {
        final full = svc.expand(start, rrule, to: to, limit: 2000);
        final jumped =
            svc.expand(start, rrule, from: from, to: to, limit: 2000);
        final filtered = full.where((d) => !d.isBefore(from)).toList();
        expect(jumped, filtered, reason: rrule);
      }
    });

    test('COUNT 规则保持精确计数，不受 from 影响', () {
      const rules = [
        'FREQ=DAILY;COUNT=800',
        'FREQ=WEEKLY;BYDAY=MO;COUNT=120',
        'FREQ=MONTHLY;COUNT=30',
      ];
      for (final rrule in rules) {
        final full = svc.expand(start, rrule, to: to, limit: 2000);
        final jumped =
            svc.expand(start, rrule, from: from, to: to, limit: 2000);
        final filtered = full.where((d) => !d.isBefore(from)).toList();
        expect(jumped, filtered, reason: rrule);
      }
    });

    test('UNTIL 规则：跳跃后仍在 UNTIL 处截断', () {
      const rrule = 'FREQ=DAILY;UNTIL=20260820';
      final full = svc.expand(start, rrule, to: to, limit: 2000);
      final jumped =
          svc.expand(start, rrule, from: from, to: to, limit: 2000);
      final filtered = full.where((d) => !d.isBefore(from)).toList();
      expect(jumped, filtered, reason: 'UNTIL 截断与完整展开一致');
      expect(jumped.length, 20, reason: '8 月 1 日 ~ 8 月 20 日共 20 个实例');
    });

    test('from 早于 start（窗口在创建期之前）：不跳跃，行为不变', () {
      final earlyFrom = AppClock.at(2024, 1, 1);
      final jumped = svc.expand(
        start,
        'FREQ=DAILY',
        from: earlyFrom,
        to: to,
        limit: 2000,
      );
      final full = svc.expand(start, 'FREQ=DAILY', to: to, limit: 2000);
      expect(
        jumped,
        full.where((d) => !d.isBefore(earlyFrom)).toList(),
      );
    });
  });

  group('skippedDates Set 化与实例判断', () {
    late AppDatabase db;
    late int id;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      id = await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '每日',
        planStart: Value(start),
        planEnd: Value(start.add(const Duration(hours: 1))),
        rrule: const Value('FREQ=DAILY'),
        createdAt: start,
      ));
    });

    tearDown(() async {
      await db.close();
    });

    test('500 条 skippedDates：getCalendarItems 正确排除跳过日', () async {
      final skipDays = <String>[
        for (var i = 0; i < 500; i++)
          AppClock.at(2024, 8, 10)
              .add(Duration(days: i))
              .toIso8601String(),
        AppClock.at(2026, 8, 5).toIso8601String(),
      ];
      await db.updateTask(
        id,
        TasksCompanion(skippedDates: Value(jsonEncode(skipDays))),
      );
      final t = (await db.getTask(id))!;
      final items = await db.getCalendarItems(from, to);
      final daySet = items
          .map((i) =>
              '${i.instanceDate.year}-${i.instanceDate.month}-${i.instanceDate.day}')
          .toSet();
      expect(daySet.contains('2026-8-5'), isFalse,
          reason: '被跳过的 8 月 5 日不得出现');
      expect(daySet.contains('2026-8-6'), isTrue);
      expect(daySet.contains('2026-8-1'), isTrue);
      expect(daySet.contains('2026-8-31'), isTrue);
      // 同步判断与日历批量结果口径一致
      expect(
        db.hasInstanceOnDaySync(
          t,
          AppClock.at(2026, 8, 5),
          const [],
          null,
        ),
        isFalse,
      );
      expect(
        db.hasInstanceOnDaySync(
          t,
          AppClock.at(2026, 8, 6),
          const [],
          null,
        ),
        isTrue,
      );
    });

    test('decodeSkippedDays 损坏 JSON 容错（按无跳过处理）', () async {
      await db.updateTask(id, TasksCompanion(skippedDates: const Value('nope')));
      final t = (await db.getTask(id))!;
      expect(db.decodeSkippedDays(t), isNull,
          reason: '损坏 JSON 返回 null，调用方按无跳过处理');
      expect(
        db.hasInstanceOnDaySync(t, AppClock.at(2026, 8, 6), const [], null),
        isTrue,
        reason: '损坏 JSON 不得影响规则命中判断',
      );
      // 日历查询同样不因损坏 JSON 崩溃
      expect(await db.getCalendarItems(from, to), isNotEmpty);
    });

    test('hasInstanceOnDaySync 例外改期语义与 expandTaskForDateWith 一致', () async {
      await db.insertException(TaskExceptionsCompanion.insert(
        taskId: id,
        instanceDate: AppClock.at(2026, 8, 5),
        action: const Value('edit'),
        overrideScheduledDate: Value(AppClock.at(2026, 8, 7)),
      ));
      final ex = await db.getExceptions(id);
      final t = (await db.getTask(id))!;
      final asyncHit = await db.expandTaskForDateWith(
        t,
        AppClock.at(2026, 8, 5),
        ex,
      );
      expect(asyncHit, isEmpty, reason: '原日期被改期移走');
      expect(
        db.hasInstanceOnDaySync(t, AppClock.at(2026, 8, 5), ex, null),
        isFalse,
        reason: '同步判断与原异步判断一致',
      );
      expect(
        db.hasInstanceOnDaySync(t, AppClock.at(2026, 8, 7), ex, null),
        isTrue,
        reason: '改期目标日视为有实例',
      );
      expect(
        db.hasInstanceOnDaySync(t, AppClock.at(2026, 8, 6), ex, null),
        isTrue,
        reason: '其余规则命中日不受影响',
      );
    });
  });
}
