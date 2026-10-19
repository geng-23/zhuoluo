import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/calendar/calendar_page.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';
import 'package:zhuoluo/main.dart';

import '../support/fake_notification_scheduler.dart';

/// 日历交互：可见视图入口、月格任务标记和当天清单
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SoundService.enabled = false;
    final fake = FakeNotificationScheduler();
    NotificationService.instance.debugOverrideScheduler = fake;
  });

  tearDown(() async {
    NotificationService.instance.debugOverrideScheduler = null;
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await db.ensureDefaultList();
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
  }

  Future<void> switchToMonthView(WidgetTester tester) async {
    // 切到日历 tab
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-view-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月视图'));
    await tester.pumpAndSettle();
  }

  testWidgets('月视图长按日期弹出快速添加面板', (tester) async {
    await pumpApp(tester);
    await switchToMonthView(tester);

    // 月格存在（找 1 号格，长按）
    final dayCell = find.text('1').first;
    expect(dayCell, findsWidgets, reason: '月视图应有日期格');
    await tester.longPress(dayCell);
    await tester.pumpAndSettle();

    // 快速添加面板出现（含标题输入框与添加按钮）
    expect(find.text('添加'), findsWidgets, reason: '长按应弹出快速添加');
  });

  testWidgets('月视图点日期先展示任务清单，可主动进入日视图', (tester) async {
    await pumpApp(tester);
    await switchToMonthView(tester);
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, 15);
    await tester.tap(
      find.byKey(ValueKey('month-day-${day.year}-${day.month}-${day.day}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('当天没有任务'), findsOneWidget);
    final scope = ProviderScope.containerOf(
      tester.element(find.byKey(const ValueKey('calendar-date-title'))),
    );
    expect(scope.read(calendarControllerProvider).view, 'month');
    await tester.tap(find.text('日视图'));
    await tester.pumpAndSettle();
    expect(scope.read(calendarControllerProvider).view, 'day');
  });

  testWidgets('系统返回关闭当天清单，保留月视图', (tester) async {
    await pumpApp(tester);
    await switchToMonthView(tester);
    final now = DateTime.now();
    final dayKey = ValueKey('month-day-${now.year}-${now.month}-15');
    await tester.tap(find.byKey(dayKey));
    await tester.pumpAndSettle();
    expect(find.text('当天没有任务'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('当天没有任务'), findsNothing);
    expect(find.byKey(dayKey), findsOneWidget);
  });

  testWidgets('迷你月历选日不改变当前视图', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-date-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-mini-month')), findsOneWidget);
    await tester.tap(find.byTooltip('下个月'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1, 15);
    await tester.tap(
      find.byKey(ValueKey('mini-day-${next.year}-${next.month}-${next.day}')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-mini-month')), findsNothing);
    final scope = ProviderScope.containerOf(
      tester.element(find.byKey(const ValueKey('calendar-date-title'))),
    );
    final state = scope.read(calendarControllerProvider);
    expect(state.view, 'week');
    expect(state.selectedDay.year, next.year);
    expect(state.selectedDay.month, next.month);
    expect(state.selectedDay.day, 15);
  });

  testWidgets('六行月份在小屏高度内完整显示', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: brightness,
              ),
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 340,
                  child: MonthView(
                    items: const [],
                    byDay: const {},
                    displayedMonth: DateTime(2026, 8),
                    selectedDay: DateTime(2026, 8, 15),
                    onDayTap: (_) {},
                    onDayLongPress: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('month-day-2026-8-31')), findsOneWidget);
      final grid = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(grid.position.maxScrollExtent, 0);
    }
  });

  testWidgets('月格显示任务标记，点按后显示可读的任务清单', (tester) async {
    await pumpApp(tester);
    // 造 5 个同一天任务（今天），月视图当天格应有摘要
    final list = await db.getDefaultList();
    final now = DateTime.now();
    for (var i = 0; i < 5; i++) {
      await db.insertTask(
        TasksCompanion.insert(
          listId: list.id,
          title: '任务$i',
          planStart: Value(DateTime(now.year, now.month, now.day, 9)),
          planEnd: Value(DateTime(now.year, now.month, now.day, 10)),
          createdAt: now,
        ),
      );
    }
    await switchToMonthView(tester);
    // 数据版本变化触发日历重载
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final dayKey = ValueKey('month-day-${now.year}-${now.month}-${now.day}');
    final dayCell = find.byKey(dayKey);
    expect(
      find.descendant(
        of: dayCell,
        matching: find.byKey(const ValueKey('calendar-task-dot-0')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dayCell, matching: find.text('+3')),
      findsOneWidget,
    );
    expect(find.text('任务0'), findsNothing);
    await tester.tap(dayCell);
    await tester.pumpAndSettle();
    expect(find.text('任务0'), findsOneWidget);
    expect(find.text('任务4'), findsOneWidget);
    await tester.tap(find.text('任务0'));
    await tester.pumpAndSettle();
    expect(find.byType(TaskDetailPage), findsOneWidget);
  });

  testWidgets('顶部只显示年月，视图切换按钮清晰可点', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    final selected = DateTime(2027, 3, 18);
    final scope = ProviderScope.containerOf(
      tester.element(find.byKey(const ValueKey('calendar-date-title'))),
    );
    scope.read(calendarControllerProvider.notifier).setSelectedDay(selected);
    await tester.pumpAndSettle();
    expect(find.text('2027年3月'), findsOneWidget);
    expect(find.text('周视图'), findsOneWidget);
    expect(find.byTooltip('添加任务'), findsNothing);
    final menuSize = tester.getSize(
      find.byKey(const ValueKey('calendar-view-menu')),
    );
    expect(menuSize.width, greaterThanOrEqualTo(80));
    await tester.tap(find.byKey(const ValueKey('calendar-view-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日视图'));
    await tester.pumpAndSettle();
    expect(find.text('2027年3月'), findsOneWidget);
  });

  testWidgets('窄屏上仍可切换视图且顶部不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpApp(tester);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-view-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月视图'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('添加任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
