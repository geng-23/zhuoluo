import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/calendar_page.dart';
import 'package:zhuoluo/features/calendar/providers.dart';

/// 丝滑翻页 + 边缘交互回归测试：
/// - 窗口缓存：翻页/切视图命中缓存零 DB（loadCount 不增）
/// - 数据版本变化 → 缓存失效重拉
/// - 边缘手势条：左缘右滑切上一个 tab、右缘左滑切下一个 tab、中间滑动不切
/// - 拖动任务块到屏幕边缘停留 → 翻周/日（Draggable 全局坐标驱动，不依赖列边界）

/// 延迟日历 DB：模拟真机异步查询时序。drift 内存库在测试 pump 内同步
/// 完成，loading:true→false 同帧合并，复现不了真机上"loading 提交 →
/// spinner 整页替换 → WeekView State 销毁"的路径（空周翻页跨缓存点
/// 拖动失效的根因）。override getCalendarItems 加 200ms 延迟来复现。
class _DelayedCalendarDb extends AppDatabase {
  _DelayedCalendarDb(super.e) : super.forTesting();

  @override
  Future<List<CalendarItem>> getCalendarItems(
    DateTime from,
    DateTime to,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return super.getCalendarItems(from, to);
  }
}

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
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '任务A',
          planStart: Value(now),
          planEnd: Value(now.add(const Duration(hours: 1))),
          createdAt: now,
        ),
      );

      final container = makeContainer();
      final controller = container.read(calendarControllerProvider.notifier);
      await controller.load();
      final first = controller.loadCount;
      expect(first, greaterThanOrEqualTo(1), reason: '首次必须查库');
      expect(controller.state.items, isNotEmpty);

      // 同周内翻页（选本周另一天，避免跨周边界）→ 命中缓存零 DB
      final monday = DateUtilsEx.mondayOf(now);
      final nextInWeek = monday.isBefore(now)
          ? monday
          : now.add(const Duration(days: 1));
      controller.setSelectedDay(nextInWeek);
      await controller.load();
      expect(controller.loadCount, first, reason: '缓存窗口内翻页不应触发 DB 查询');

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
      expect(
        controller.loadCount,
        greaterThan(first),
        reason: '超出 31 天缓冲应重新查询',
      );
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
      expect(
        controller.loadCount,
        greaterThan(first),
        reason: '数据版本变化后缓存失效，必须重查',
      );
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
      await tester.flingFrom(
        const Offset(400, 400),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(left + right, 0, reason: '中间滑动翻周/日，不切 tab');

      // 反向
      await tester.flingFrom(
        const Offset(400, 400),
        const Offset(200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(left + right, 0);
    });
  });

  group('拖动任务块到边缘翻周/日（Draggable 全局坐标驱动）', () {
    testWidgets('拖动任务到屏幕右缘停留 300ms → 翻到下一周', (tester) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = DateTime(now.year, now.month, now.day, 10, 0);
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '拖拽任务',
          planStart: Value(start),
          planEnd: Value(start.add(const Duration(hours: 1))),
          createdAt: now,
        ),
      );

      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();

      final before = container.read(calendarControllerProvider).selectedDay;

      // 长按任务块启动拖拽（600ms > 长按阈值）
      final block = find.text('拖拽任务');
      expect(block, findsWidgets, reason: '任务块应渲染在时间轴');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 拖到屏幕右缘（85% 区外；固定目标坐标——任务列随星期变化，
      // moveBy 只在任务恰在右数几列时才进入边缘区）
      await gesture.moveTo(const Offset(760, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 边缘停留 > 300ms
      await gesture.up();
      await tester.pumpAndSettle();

      final after = container.read(calendarControllerProvider).selectedDay;
      expect(after.isAfter(before), isTrue, reason: '拖到右缘停留应翻到下一周');
    });

    testWidgets('拖动任务到屏幕左缘停留 300ms → 翻到上一周', (tester) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = DateTime(now.year, now.month, now.day, 10, 0);
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '拖拽任务2',
          planStart: Value(start),
          planEnd: Value(start.add(const Duration(hours: 1))),
          createdAt: now,
        ),
      );

      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();

      final before = container.read(calendarControllerProvider).selectedDay;

      final block = find.text('拖拽任务2');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 拖到屏幕左缘（Draggable 全局坐标检测，不依赖列边界）
      await gesture.moveTo(const Offset(10, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await gesture.up();
      await tester.pumpAndSettle();

      final after = container.read(calendarControllerProvider).selectedDay;
      expect(after.isBefore(before), isTrue, reason: '拖到左缘停留应翻到上一周');
    });
  });

  group('连续翻周 + 虚影跨页 + 左时间栏贴边', () {
    Future<ProviderContainer> pumpCalendarWithTask(
      WidgetTester tester,
      String title,
    ) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = DateTime(now.year, now.month, now.day, 10, 0);
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: title,
          planStart: Value(start),
          planEnd: Value(start.add(const Duration(hours: 1))),
          createdAt: now,
        ),
      );
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    Future<TestGesture> longPressDrag(WidgetTester tester, String title) async {
      final block = find.text(title);
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return gesture;
    }

    testWidgets('长按任务块不动直接松手：计划时间不变（不落到时间轴顶部）', (tester) async {
      await pumpCalendarWithTask(tester, '不动任务');
      final taskId = (await db.allTasksForBackup())
          .firstWhere((t) => t.title == '不动任务')
          .id;
      final original = (await db.getTask(taskId))!.planStart;
      // 长按进入拖动状态，但不移动
      final gesture = await longPressDrag(tester, '不动任务');
      await gesture.up();
      await tester.pumpAndSettle();
      final updated = (await db.getTask(taskId))!.planStart;
      expect(
        updated,
        original,
        reason:
            '长按不动松手不应改期（修复前 dragGlobalPos 为 null，dy=0 兜底会把任务挪到 06:00 顶部）',
      );
    });

    testWidgets('右缘停留连续翻周：翻第一周后 500ms 自动续翻第二周', (tester) async {
      final container = await pumpCalendarWithTask(tester, '拖拽任务A');
      final before = container.read(calendarControllerProvider).selectedDay;

      final gesture = await longPressDrag(tester, '拖拽任务A');
      await gesture.moveTo(const Offset(760, 400)); // 右缘 85% 区外
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 首次 300ms 触发
      await tester.pumpAndSettle();
      final after1 = container.read(calendarControllerProvider).selectedDay;
      expect(after1.isAfter(before), isTrue, reason: '首次边缘停留应翻周');

      // 指针仍停右缘：连续链 500ms 后自动续翻
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      final after2 = container.read(calendarControllerProvider).selectedDay;
      expect(after2.isAfter(after1), isTrue, reason: '边缘停留应自动续翻第二周（连续拖到多个周以后）');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('翻周后虚影跟随新周边缘列（跨页保持），松手消失', (tester) async {
      await pumpCalendarWithTask(tester, '拖拽任务B');
      final gesture = await longPressDrag(tester, '拖拽任务B');
      await gesture.moveTo(const Offset(760, 400)); // 右缘 85% 区外
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 翻周
      await tester.pumpAndSettle();

      // 虚影（'HH:mm - HH:mm' 格式文本）应显示在新周
      expect(
        find.textContaining(RegExp(r'\d{2}:\d{2} - \d{2}:\d{2}')),
        findsOneWidget,
        reason: '翻周后虚影应跟随显示（此前翻页即消失）',
      );

      // 继续停留续翻，虚影仍跟随
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp(r'\d{2}:\d{2} - \d{2}:\d{2}')),
        findsOneWidget,
        reason: '连续翻周时虚影持续跟随',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp(r'\d{2}:\d{2} - \d{2}:\d{2}')),
        findsNothing,
        reason: '松手后虚影消失',
      );
    });

    testWidgets('指针离开边缘后停止连续翻周', (tester) async {
      final container = await pumpCalendarWithTask(tester, '拖拽任务C');
      final gesture = await longPressDrag(tester, '拖拽任务C');
      await gesture.moveTo(const Offset(760, 400)); // 右缘 85% 区外
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 翻一周
      await tester.pumpAndSettle();
      final after1 = container.read(calendarControllerProvider).selectedDay;

      // 拖回中间（离开边缘区）→ 连续链应取消
      await gesture.moveTo(const Offset(400, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900)); // 超过 800ms 续翻间隔
      await tester.pumpAndSettle();
      expect(
        container.read(calendarControllerProvider).selectedDay,
        after1,
        reason: '离开边缘后不应续翻',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('左时间栏贴屏幕左缘（左侧 0 收窄）', (tester) async {
      await db.ensureDefaultList();
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      // 时间刻度 '06:00' 左缘应贴近屏幕左缘（<12px；收窄 24px 时为 18px+）
      final left = tester.getTopLeft(find.text('06:00').first).dx;
      expect(left, lessThan(12), reason: '左时间栏应贴屏幕左缘（实际 $left）');
    });

    testWidgets('边缘慢速滑动（位移 36px，无速度）也能切 tab', (tester) async {
      await db.ensureDefaultList();
      var left = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: CalendarPage(onNavigateLeft: () => left++)),
        ),
      );
      await tester.pumpAndSettle();

      // 左缘缓慢滑动 36px（低速度）
      final gesture = await tester.startGesture(const Offset(12, 400));
      await gesture.moveBy(const Offset(36, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(left, 1, reason: '位移 ≥32px 即触发切 tab，不依赖速度');
    });

    testWidgets('纵向滚动带横向抖动不切 tab（起点左缘）', (tester) async {
      await db.ensureDefaultList();
      var left = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: CalendarPage(onNavigateLeft: () => left++)),
        ),
      );
      await tester.pumpAndSettle();

      // 起点在左缘 15% 区；纵向滚动 200px，途中多次轻微横向抖动
      final gesture = await tester.startGesture(const Offset(12, 400));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump();
        if (i.isEven) {
          await gesture.moveBy(const Offset(8, 0));
          await tester.pump();
        }
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(left, 0, reason: '纵向滚动中的横向抖动不应切 tab');
    });

    testWidgets('轻微斜向移动不切 tab（dx 明显小于 dy）', (tester) async {
      await db.ensureDefaultList();
      var left = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: CalendarPage(onNavigateLeft: () => left++)),
        ),
      );
      await tester.pumpAndSettle();

      // 起点左缘；斜向移动 dx=40、dy=50（纵向主导，非横向意图）
      final gesture = await tester.startGesture(const Offset(12, 400));
      await gesture.moveBy(const Offset(40, 50));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(left, 0, reason: '斜向移动（dx<dy）不应切 tab');
    });

    testWidgets('左缘手势区（44px 覆盖时间栏）不挡任务块点击', (tester) async {
      await pumpCalendarWithTask(tester, '拖拽任务D');
      // 点击任务块（时间栏右侧的列区域）→ 实例操作层弹出
      await tester.tap(find.text('拖拽任务D').first);
      await tester.pumpAndSettle();
      expect(
        find.text('完成本次'),
        findsWidgets,
        reason: '任务块点击应正常弹出操作层（左缘手势区不遮挡）',
      );
      expect(find.text('查看详情'), findsWidgets);
    });
  });

  group('全局指针事件驱动 + 边缘 15% 切 tab + 视图铺满', () {
    Future<ProviderContainer> pumpCalendarWithTask(
      WidgetTester tester,
      String title,
    ) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      final start = DateTime(now.year, now.month, now.day, 10, 0);
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: title,
          planStart: Value(start),
          planEnd: Value(start.add(const Duration(hours: 1))),
          createdAt: now,
        ),
      );
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('15% 区滑动切 tab（左缘 x=100 右滑 / 右缘 x=700 左滑）', (tester) async {
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

      // 左 15% 区内右滑（x=100 < 120）
      final g1 = await tester.startGesture(const Offset(100, 400));
      await g1.moveBy(const Offset(40, 0));
      await tester.pump();
      await g1.up();
      await tester.pumpAndSettle();
      expect(left, 1, reason: '左 15% 区右滑应切上一个 tab');

      // 右 15% 区内左滑（x=700 > 680）
      final g2 = await tester.startGesture(const Offset(700, 400));
      await g2.moveBy(const Offset(-40, 0));
      await tester.pump();
      await g2.up();
      await tester.pumpAndSettle();
      expect(right, 1, reason: '右 15% 区左滑应切下一个 tab');
    });

    testWidgets('长按拖动任务不误触切 tab', (tester) async {
      await pumpCalendarWithTask(tester, '长按任务');
      var left = 0;
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: CalendarPage(onNavigateLeft: () => left++)),
        ),
      );
      await tester.pumpAndSettle();

      final block = find.text('长按任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      // 真实等待 400ms（超过 350ms 长按窗口——拖动任务路径）
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(left, 0, reason: '长按拖动任务不应触发切 tab');
    });

    testWidgets('视图铺满：周日列右缘贴屏幕右缘', (tester) async {
      await db.ensureDefaultList();
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      // 视图铺满：PageView 右缘应贴屏幕右缘（此前右缘 40px 收窄会留空白）
      final rect = tester.getRect(find.byType(PageView).last);
      expect(
        rect.right,
        greaterThan(790),
        reason: '视图应铺满（右缘=屏宽，实际 ${rect.right}）',
      );
    });

    testWidgets('右缘连续翻页后拖回左缘：反向翻页（全局 route 驱动）', (tester) async {
      final container = await pumpCalendarWithTask(tester, '反向任务');
      final before = container.read(calendarControllerProvider).selectedDay;
      final block = find.text('反向任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 右缘首翻（固定目标坐标，避免任务列随星期变化）
      await gesture.moveTo(const Offset(760, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final after1 = container.read(calendarControllerProvider).selectedDay;
      expect(after1.isAfter(before), isTrue, reason: '右缘应翻到下一周');

      // 不松手拖回左缘（Draggable 可能已跨页被 evict——全局 route 接管）
      await gesture.moveTo(const Offset(10, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final after2 = container.read(calendarControllerProvider).selectedDay;
      expect(after2.isBefore(after1), isTrue, reason: '拖回左缘应反向翻页（全局指针事件驱动）');
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('连续翻 6 页后边缘松手：任务改期成功（落点兜底不回退）', (tester) async {
      await pumpCalendarWithTask(tester, '兜底任务');
      final taskId = (await db.allTasksForBackup())
          .firstWhere((t) => t.title == '兜底任务')
          .id;
      final original = (await db.getTask(taskId))!.planStart;
      final block = find.text('兜底任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveTo(const Offset(760, 400)); // 右缘 85% 区外
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 首翻
      await tester.pumpAndSettle();
      // 连续续翻 6 次（远超 PageView cacheExtent——Draggable 被 evict；
      // 链间隔 500ms → 每次推进 550ms 恰翻一页）
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 550));
        await tester.pumpAndSettle();
      }
      // 回归保护：跨页超过 5 次后虚影仍显示（onDraggableCanceled
      // 曾清共享状态导致任务块"闪退"回原位）
      expect(find.text('兜底任务'), findsWidgets, reason: '翻 6 页后虚影仍应显示（任务块不闪退）');
      // 在边缘松手（无 DragTarget 命中——落点兜底执行改期）
      await gesture.up();
      await tester.pumpAndSettle();
      final updated = (await db.getTask(taskId))!;
      expect(
        updated.planStart,
        isNot(original),
        reason: '边缘松手应改期成功（落点兜底，任务不回退）',
      );
    });

    testWidgets('连续翻多页后松手：落点时间与不翻页一致（左/右缘跨缓存点）', (tester) async {
      Future<DateTime> dropAt(String title,
          {required int pages, required double edgeX}) async {
        await pumpCalendarWithTask(tester, title);
        final taskId = (await db.allTasksForBackup())
            .firstWhere((t) => t.title == title)
            .id;
        final block = find.text(title);
        final gesture = await tester.startGesture(tester.getCenter(block.first));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (pages > 0) {
          await gesture.moveTo(Offset(edgeX, 400)); // 边缘首翻
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          // 连续续翻（Draggable 被 evict——落点走兜底）
          for (var i = 0; i < pages; i++) {
            await tester.pump(const Duration(milliseconds: 550));
            await tester.pumpAndSettle();
          }
        }
        // 移到视口中部同一位置松手
        await gesture.moveTo(const Offset(400, 450));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        return (await db.getTask(taskId))!.planStart!;
      }

      final direct = await dropAt('落点A', pages: 0, edgeX: 0);
      // 右缘翻 10 页（跨 ±45 天缓存重基点；此前第 10 页附近失效）
      final right = await dropAt('落点B', pages: 10, edgeX: 760);
      // 左缘翻 6 页（此前第 5 页附近失效；左缘触发区 x<12%）
      final left = await dropAt('落点C', pages: 6, edgeX: 16);
      expect(
        right.hour,
        direct.hour,
        reason: '右缘翻 10 页后落点小时应与不翻页一致（修复前第 10 页失效）',
      );
      expect(
        right.minute,
        direct.minute,
        reason: '右缘翻 10 页后落点分钟应与不翻页一致',
      );
      expect(
        left.hour,
        direct.hour,
        reason: '左缘翻 6 页后落点小时应与不翻页一致（修复前第 5 页失效）',
      );
      expect(
        left.minute,
        direct.minute,
        reason: '左缘翻 6 页后落点分钟应与不翻页一致',
      );
    });

    testWidgets('胶囊在视口内且水平错开手指：不被上缘遮挡、不被手指挡住', (tester) async {
      await pumpCalendarWithTask(tester, '胶囊任务');
      final block = find.text('胶囊任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 拖到屏幕顶部（此前胶囊按列内坐标定位可能超出上缘被裁剪；
      // 后按 padding 当上界 → 被 clamp 到 AppBar 之后完全遮挡）
      await gesture.moveTo(const Offset(400, 60));
      await tester.pump();
      final capsule = find.byIcon(Icons.schedule);
      expect(capsule, findsWidgets, reason: '拖动任务时应显示时间胶囊');
      final rect = tester.getRect(capsule.first);
      // 视口内：胶囊 top 不低于时间轴区域顶部（AppBar 之后不再被遮挡）
      final viewTop = tester.getRect(find.byType(PageView).last).top;
      expect(
        rect.top,
        greaterThanOrEqualTo(viewTop),
        reason: '胶囊不应被上缘/AppBar 遮挡（top=${rect.top} < 视口顶 $viewTop）',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(600),
        reason: '胶囊不应超出屏幕下缘（实际 bottom=${rect.bottom}）',
      );
      // 水平错开手指：胶囊中心与手指 x 距离 ≥ 24（手指不挡胶囊）
      final fingerX = 400.0;
      expect(
        (rect.center.dx - fingerX).abs(),
        greaterThanOrEqualTo(24),
        reason: '胶囊应水平错开手指（中心 dx=${rect.center.dx}，手指 x=400）',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('翻页后手指微漂移（保持区内）→ 500ms 间隔连续翻页不间断', (tester) async {
      final container = await pumpCalendarWithTask(tester, '微漂任务');
      final block = find.text('微漂任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveTo(const Offset(760, 400)); // 右缘触发区
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 首翻
      await tester.pumpAndSettle();
      final after1 = container.read(calendarControllerProvider).selectedDay;

      // 微漂移到 80%（保持区内：>65%）——链不应中断
      await gesture.moveTo(const Offset(640, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 550)); // 链 500ms → 续翻
      await tester.pumpAndSettle();
      final after2 = container.read(calendarControllerProvider).selectedDay;
      expect(after2.isAfter(after1), isTrue, reason: '保持区内微漂移应继续翻页（不间断）');
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('翻页后拖到视口顶部：垂直自动滚动仍工作（全局 route 接管）', (tester) async {
      await pumpCalendarWithTask(tester, '滚动任务');
      final block = find.text('滚动任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 右缘翻一页（跨页后 Draggable 可能被 evict——全局 route 接管垂直滚动）
      await gesture.moveTo(const Offset(760, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      // 拖到视口底部（下滑自动滚动触发区：距视口底 <90px；时间轴初始在
      // 顶部——向下滚动必然增加 offset）
      await gesture.moveTo(const Offset(400, 580));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // 16ms 步进滚动
      // 时间轴应已向上滚动（列版 + 全局 route 双源驱动，至少一方生效）
      var pixels = 0.0;
      final scrollables = find.byType(Scrollable);
      final count = tester.widgetList(scrollables).length;
      for (var i = 0; i < count; i++) {
        final pos = tester.state<ScrollableState>(scrollables.at(i)).position;
        if (pos.axis == Axis.vertical) {
          pixels = pos.pixels;
          break;
        }
      }
      expect(
        pixels,
        greaterThan(0),
        reason: '翻页后拖到视口顶部应自动滚动时间轴（实际 pixels=$pixels）',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('跨页翻走再返回：原任务块保持半透明（共享状态驱动）', (tester) async {
      await pumpCalendarWithTask(tester, '透明任务');
      final block = find.text('透明任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 右缘翻两页（跨页后 Draggable 可能被 evict——childWhenDragging 失效）
      await gesture.moveTo(const Offset(760, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      // 拖回左缘翻回原周（不松手）
      await gesture.moveTo(const Offset(10, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      // 原任务块应可见且半透明（Opacity 0.3，与同页拖动一致）
      expect(find.text('透明任务'), findsWidgets, reason: '返回原页原任务块应可见');
      final dimmed = find.ancestor(
        of: find.text('透明任务'),
        matching: find.byWidgetPredicate(
          (w) => w is Opacity && w.opacity == 0.3,
        ),
      );
      expect(dimmed, findsWidgets, reason: '跨页返回原任务块应保持半透明（与同页拖动一致）');
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('边缘翻页后新页继承滚动位置（不跳回顶部）', (tester) async {
      await pumpCalendarWithTask(tester, '继承任务');
      final scrollables = find.byType(Scrollable);
      final count = tester.widgetList(scrollables).length;
      // 滚动时间轴到中间（500px）——时间栏 + 内容都要跳（内容触发 share 更新）
      for (var i = 0; i < count; i++) {
        final pos = tester.state<ScrollableState>(scrollables.at(i)).position;
        if (pos.axis == Axis.vertical) {
          pos.jumpTo(500);
        }
      }
      await tester.pumpAndSettle();
      // 长按拖动到右缘翻一页（新页应继承滚动位置）
      final block = find.text('继承任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveTo(const Offset(760, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      var pixels = -1.0;
      for (var i = 0; i < count; i++) {
        final pos = tester.state<ScrollableState>(scrollables.at(i)).position;
        if (pos.axis == Axis.vertical) {
          pixels = pos.pixels;
          break;
        }
      }
      expect(
        pixels,
        closeTo(500, 60),
        reason: '翻页后新页应继承滚动位置（实际 $pixels，修复前被污染为 0）',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('滚动后同页拖动任务松手：滚动位置保持（不跳回顶部）', (tester) async {
      await pumpCalendarWithTask(tester, '保持任务');
      final scrollables = find.byType(Scrollable);
      final count = tester.widgetList(scrollables).length;
      for (var i = 0; i < count; i++) {
        final pos = tester.state<ScrollableState>(scrollables.at(i)).position;
        if (pos.axis == Axis.vertical) {
          pos.jumpTo(500);
        }
      }
      await tester.pumpAndSettle();
      // 同页内轻微拖动（不进边缘区、不翻页）后松手改期
      final block = find.text('保持任务');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveBy(const Offset(20, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      var pixels = -1.0;
      for (var i = 0; i < count; i++) {
        final pos = tester.state<ScrollableState>(scrollables.at(i)).position;
        if (pos.axis == Axis.vertical) {
          pixels = pos.pixels;
          break;
        }
      }
      expect(pixels, closeTo(500, 60), reason: '同页拖动松手后滚动位置应保持（实际 $pixels）');
    });

    testWidgets('普通翻页后仍可上下滚动时间轴', (tester) async {
      await db.ensureDefaultList();
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();

      ScrollPosition visibleContentPosition() {
        final scrollables = find.byType(Scrollable);
        for (var i = 0; i < tester.widgetList(scrollables).length; i++) {
          final position = tester
              .state<ScrollableState>(scrollables.at(i))
              .position;
          if (position.axis != Axis.vertical || position.maxScrollExtent <= 0) {
            continue;
          }
          final rect = tester.getRect(scrollables.at(i));
          if (rect.left > 40 && rect.contains(const Offset(400, 450))) {
            return position;
          }
        }
        throw StateError('未找到当前页时间轴内容滚动器');
      }

      // 先横向翻到下一页，再在新页内容区上下滑动。
      await tester.flingFrom(
        const Offset(400, 250),
        const Offset(-240, 0),
        1200,
      );
      await tester.pumpAndSettle();
      final afterPageTurn = visibleContentPosition();
      final beforeUp = afterPageTurn.pixels;

      await tester.dragFrom(const Offset(400, 450), const Offset(0, -220));
      await tester.pumpAndSettle();
      final afterUp = visibleContentPosition().pixels;
      expect(afterUp, greaterThan(beforeUp), reason: '翻页后应能向上滚动时间轴');

      await tester.dragFrom(const Offset(400, 300), const Offset(0, 220));
      await tester.pumpAndSettle();
      expect(
        visibleContentPosition().pixels,
        lessThan(afterUp),
        reason: '翻页后应能向下滚回时间轴',
      );
    });

    testWidgets('长按选时纵向拖动不触发边缘翻页', (tester) async {
      await db.ensureDefaultList();
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      final before = container.read(calendarControllerProvider).selectedDay;

      // 右侧列靠近边缘，模拟周末/周五附近创建任务时的纵向拖选。
      final gesture = await tester.startGesture(const Offset(760, 300));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveTo(const Offset(760, 460));
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        container.read(calendarControllerProvider).selectedDay,
        before,
        reason: '纯纵向长按选时不应触发边缘翻页',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('远距离跳转停在目标位置：周/日/月视图不落在中间页', (tester) async {
      await db.ensureDefaultList();
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      final notifier = container.read(calendarControllerProvider.notifier);

      // 周视图：远距离跳到 2021 年（此前动画被 onPageChanged 回跳打断，
      // 可能停在中间周——如 2022）
      final targetWeek = DateTime(2021, 3, 15);
      notifier.setSelectedDay(targetWeek);
      await tester.pumpAndSettle();
      expect(
        container.read(calendarControllerProvider).selectedDay,
        targetWeek,
        reason: '周视图远距离跳转应停在目标日期（不落在中间周）',
      );

      // 日视图：远距离跳转（此前停在中间日，如点 8/27 出 8/12）
      final targetDay = DateTime(2021, 9, 27);
      notifier.setSelectedDayWithView(targetDay, 'day');
      await tester.pumpAndSettle();
      expect(
        container.read(calendarControllerProvider).selectedDay,
        targetDay,
        reason: '日视图远距离跳转应停在目标日期（不落在中间日）',
      );

      // 月视图：远距离跳月（此前停在中间月，如 2021→2022）
      notifier.setSelectedDayWithView(DateTime(2026, 1, 10), 'month');
      await tester.pumpAndSettle();
      expect(
        container.read(calendarControllerProvider).displayedMonth,
        DateTime(2026, 1, 1),
        reason: '月视图远距离跳转应停在目标月份（不落在中间月）',
      );
    });
  });

  testWidgets('空数据周翻页跨缓存点：不显示 spinner、WeekView 存活（拖拽不失效）', (tester) async {
    final delayedDb = _DelayedCalendarDb(NativeDatabase.memory());
    addTearDown(delayedDb.close);
    await delayedDb.ensureDefaultList();
    final list = await delayedDb.getDefaultList();
    final today = DateTime.now();
    await delayedDb.insertTask(
      TasksCompanion.insert(
        listId: list.id,
        title: '本周任务',
        planStart: Value(DateTime(today.year, today.month, today.day, 10)),
        planEnd: Value(DateTime(today.year, today.month, today.day, 11)),
        createdAt: today,
      ),
    );
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(delayedDb)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    // 首载：延迟 200ms → spinner → 完成
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '首载应显示 spinner');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '首载完成 spinner 消失');
    expect(find.text('本周任务'), findsWidgets, reason: '本周任务应显示');

    final controller = container.read(calendarControllerProvider.notifier);
    final monday = DateUtilsEx.mondayOf(today);
    // 切到空周（+7 天，缓存窗口内命中，无延迟）——items 应空
    controller.setSelectedDay(monday.add(const Duration(days: 7)));
    await tester.pumpAndSettle();
    expect(
      container.read(calendarControllerProvider).items,
      isEmpty,
      reason: '翻到无任务的空周，items 应为空',
    );
    // 切到 +60 天（超出 ±45 天缓存窗口 → 未命中 → 延迟查询挂起）
    // 修复前：items 空被误判"未加载"→ 置 loading → 挂起中 spinner 整页
    // 替换 AnimatedSwitcher → WeekView State 销毁（拖拽共享状态全灭）
    controller.setSelectedDay(monday.add(const Duration(days: 60)));
    await tester.pump(const Duration(milliseconds: 50)); // 查询挂起中（<200ms）
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '空周翻页跨缓存点不应显示 spinner（修复前整页替换销毁 WeekView State）',
    );
    expect(find.text('06:00'), findsWidgets,
        reason: 'WeekView 应保持存活（时间轴刻度仍在，未被 spinner 替换）');
    // 查询完成后数据到位，视图正常
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  group('全天任务长按拖动改期（置顶区改日 / 时间轴转定时）', () {
    Future<TestGesture> longPressOn(WidgetTester tester, String title) async {
      final block = find.text(title);
      expect(block, findsWidgets, reason: '全天任务块应渲染在置顶区');
      final gesture = await tester.startGesture(tester.getCenter(block.first));
      // 600ms > 长按阈值
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return gesture;
    }

    Future<int> insertAllDay(DateTime day, {String rrule = '', String title = ''}) async {
      await db.ensureDefaultList();
      final list = await db.getDefaultList();
      return db.insertTask(TasksCompanion.insert(
        listId: list.id,
        title: title,
        isAllDay: const Value(true),
        planStart: Value(day),
        planEnd: Value(day.add(const Duration(days: 1))),
        rrule: Value(rrule),
        createdAt: now,
      ));
    }

    Future<void> pumpCalendar(WidgetTester tester) async {
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('全天任务长按拖到另一天置顶区：保持全天改期到该日', (tester) async {
      final monday = DateUtilsEx.mondayOf(now);
      final taskDay = monday.add(const Duration(days: 3)); // 周中，两侧均有邻列
      final taskId = await insertAllDay(taskDay, title: '全天A');
      await pumpCalendar(tester);

      final blockCenter = tester.getCenter(find.text('全天A').first);
      final gesture = await tester.startGesture(blockCenter);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 水平拖到相邻日（保持 y 在置顶区内，不触发边缘翻周）
      await gesture.moveTo(blockCenter + Offset((800 - 44) / 7, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final t = (await db.getTask(taskId))!;
      expect(t.isAllDay, isTrue, reason: '置顶区落点保持全天');
      expect(t.planStart, taskDay.add(const Duration(days: 1)),
          reason: '全天任务改期到相邻日');
      expect(t.planEnd, taskDay.add(const Duration(days: 2)),
          reason: '全天结束为改期次日 00:00');
    });

    testWidgets('全天重复任务长按拖到另一天：弹确认后保持全天改期到该日', (tester) async {
      final monday = DateUtilsEx.mondayOf(now);
      final taskDay = monday.add(const Duration(days: 3));
      final taskId = await insertAllDay(
        taskDay,
        rrule: 'FREQ=DAILY',
        title: '全天系列',
      );
      await pumpCalendar(tester);

      final blockCenter = tester.getCenter(find.text('全天系列').first);
      final gesture = await tester.startGesture(blockCenter);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.moveTo(blockCenter + Offset((800 - 44) / 7, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 系列确认弹窗
      expect(find.text('更改整个系列？'), findsOneWidget,
          reason: '重复任务拖动应弹系列确认');
      await tester.tap(find.text('更改整个系列'));
      await tester.pumpAndSettle();

      final t = (await db.getTask(taskId))!;
      expect(t.isAllDay, isTrue, reason: '全天系列置顶区落点保持全天');
      expect(t.planStart, taskDay.add(const Duration(days: 1)),
          reason: '全天系列改期到相邻日');
    });

    testWidgets('全天任务长按拖进时间轴：转为 1 小时时段任务', (tester) async {
      final monday = DateUtilsEx.mondayOf(now);
      final taskDay = monday.add(const Duration(days: 3));
      final taskId = await insertAllDay(taskDay, title: '全天B');
      await pumpCalendar(tester);

      final blockCenter = tester.getCenter(find.text('全天B').first);
      final gesture = await tester.startGesture(blockCenter);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 垂直拖进时间轴（y=400 在时间轴范围内），x 保持原列
      await gesture.moveTo(Offset(blockCenter.dx, 400));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final t = (await db.getTask(taskId))!;
      expect(t.isAllDay, isFalse, reason: '拖进时间轴转定时');
      final dur = t.planEnd!.difference(t.planStart!);
      expect(dur, const Duration(hours: 1),
          reason: '全天转定时时长按 1 小时（C5-3 先例，不跨天）');
      expect(
        DateUtilsEx.sameDay(t.planStart!, taskDay),
        isTrue,
        reason: '转定时后仍落在原日期',
      );
    });
  });
}
