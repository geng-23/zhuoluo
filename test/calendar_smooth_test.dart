import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/calendar_page.dart';
import 'package:zhuoluo/features/calendar/providers.dart';

/// 丝滑翻页 + 边缘交互回归测试：
/// - 窗口缓存：翻页/切视图命中缓存零 DB（loadCount 不增）
/// - 数据版本变化 → 缓存失效重拉
/// - 边缘手势条：左缘右滑切上一个 tab、右缘左滑切下一个 tab、中间滑动不切
/// - 拖动任务块到屏幕边缘停留 → 翻周/日（Draggable 全局坐标驱动，不依赖列边界）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('窗口缓存（丝滑翻页）', () {
    test('缓存窗口内翻页零 DB：loadCount 不增且数据就绪', () async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '任务A',
        planStart: Value(now),
        planEnd: Value(now.add(const Duration(hours: 1))),
        createdAt: now,
      ));

      final container = makeContainer();
      final controller = container.read(calendarControllerProvider.notifier);
      await controller.load();
      final first = controller.loadCount;
      expect(first, greaterThanOrEqualTo(1), reason: '首次必须查库');
      expect(controller.state.items, isNotEmpty);

      // 同周内翻页（+1 天）：命中缓存，零 DB
      controller.setSelectedDay(now.add(const Duration(days: 1)));
      await controller.load();
      expect(controller.loadCount, first,
          reason: '缓存窗口内翻页不应触发 DB 查询');
      expect(controller.state.items, isNotEmpty, reason: '数据立即就绪');

      // 周视图边界内（+6 天）：仍命中缓存（±31 天缓冲）
      controller.setSelectedDay(now.add(const Duration(days: 6)));
      await controller.load();
      expect(controller.loadCount, first);
    });

    test('超出缓存窗口（+60 天）→ 触发补查', () async {
      await db.ensureDefaultList();
      final container = makeContainer();
      final controller = container.read(calendarControllerProvider.notifier);
      await controller.load();
      final first = controller.loadCount;

      controller.setSelectedDay(now.add(const Duration(days: 60)));
      await controller.load();
      expect(controller.loadCount, greaterThan(first),
          reason: '超出 31 天缓冲应重新查询');
    });

    test('周↔日视图切换命中缓存（不触发 DB）', () async {
      await db.ensureDefaultList();
      final container = makeContainer();
      final controller = container.read(calendarControllerProvider.notifier);
      await controller.load();
      final first = controller.loadCount;

      controller.setView('day');
      await controller.load();
      expect(controller.loadCount, first, reason: '日视图范围 ⊆ 周视图缓存');

      controller.setView('week');
      await controller.load();
      expect(controller.loadCount, first, reason: '周视图范围 ⊆ 日视图缓存');
    });

    test('数据版本变化 → 缓存失效重拉（新数据可见）', () async {
      await db.ensureDefaultList();
      final container = makeContainer();
      final controller = container.read(calendarControllerProvider.notifier);
      await controller.load();
      final first = controller.loadCount;

      // 模拟他页写操作（bump 数据版本 → 监听强制重载）
      container.read(dataVersionProvider.notifier).state++;
      await controller.load();
      expect(controller.loadCount, greaterThan(first),
          reason: '数据版本变化后缓存失效，必须重查');
    });
  });

  group('边缘滑动切 tab', () {
    testWidgets('左边缘右滑 → 切上一个 tab 回调', (tester) async {
      await db.ensureDefaultList();
      var left = 0;
      var right = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: CalendarPage(
              onNavigateLeft: () => left++,
              onNavigateRight: () => right++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 左边缘（x=12 < 24dp 手势区）快速右滑
      await tester.flingFrom(const Offset(12, 400), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(left, 1, reason: '左缘右滑应触发切上一个 tab');
      expect(right, 0);
    });

    testWidgets('右边缘左滑 → 切下一个 tab 回调', (tester) async {
      await db.ensureDefaultList();
      var left = 0;
      var right = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: CalendarPage(
              onNavigateLeft: () => left++,
              onNavigateRight: () => right++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.flingFrom(
        const Offset(788, 400),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(right, 1, reason: '右缘左滑应触发切下一个 tab');
      expect(left, 0);
    });

    testWidgets('中间区域滑动 → 不切 tab（翻周/日）', (tester) async {
      await db.ensureDefaultList();
      var left = 0;
      var right = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: CalendarPage(
              onNavigateLeft: () => left++,
              onNavigateRight: () => right++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 中间区域 fling（PageView 翻周）
      await tester.flingFrom(const Offset(400, 400), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(left + right, 0, reason: '中间滑动翻周/日，不切 tab');

      // 反向
      await tester.flingFrom(const Offset(400, 400), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(left + right, 0);
    });
  });

  group('拖动任务块到边缘翻周/日（Draggable 全局坐标驱动）', () {
    testWidgets('拖动任务到屏幕右缘停留 300ms → 翻到下一周', (tester) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = DateTime(now.year, now.month, now.day, 10, 0);
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '拖拽任务',
        planStart: Value(start),
        planEnd: Value(start.add(const Duration(hours: 1))),
        createdAt: now,
      ));

      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();

      final before =
          container.read(calendarControllerProvider).selectedDay;

      // 长按任务块启动拖拽（600ms > 长按阈值）
      final block = find.text('拖拽任务');
      expect(block, findsWidgets, reason: '任务块应渲染在时间轴');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 拖到屏幕右缘（边缘手势区/PageView 外，依赖 Draggable 全局坐标检测）
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 边缘停留 > 300ms
      await gesture.up();
      await tester.pumpAndSettle();

      final after = container.read(calendarControllerProvider).selectedDay;
      expect(
        after.isAfter(before),
        isTrue,
        reason: '拖到右缘停留应翻到下一周',
      );
    });

    testWidgets('拖动任务到屏幕左缘停留 300ms → 翻到上一周', (tester) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = DateTime(now.year, now.month, now.day, 10, 0);
      await db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: '拖拽任务2',
        planStart: Value(start),
        planEnd: Value(start.add(const Duration(hours: 1))),
        createdAt: now,
      ));

      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();

      final before =
          container.read(calendarControllerProvider).selectedDay;

      final block = find.text('拖拽任务2');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 拖到屏幕左缘（Draggable 全局坐标检测，不依赖列边界）
      await gesture.moveBy(const Offset(-560, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await gesture.up();
      await tester.pumpAndSettle();

      final after = container.read(calendarControllerProvider).selectedDay;
      expect(after.isBefore(before), isTrue, reason: '拖到左缘停留应翻到上一周');
    });
  });
}






