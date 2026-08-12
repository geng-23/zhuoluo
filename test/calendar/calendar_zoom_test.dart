import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/calendar_page.dart';
import 'package:zhuoluo/features/calendar/providers.dart';

/// 周/日视图时间轴双指缩放回归测试：
/// - 双指张开放大 / 捏合缩小 → pixelPerHourProvider 动态变化
/// - 缩到最小 → 时间轴内容高 ≤ 视口（06:00-23:00 整屏可见，零滚动）
/// - 单指拖动/翻页不受影响（缩放仅 2 指生效）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
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

  Future<void> pumpCalendar(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await db.ensureDefaultList();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 双指捏合/张开：两指从 fromSpread 水平距离移到 toSpread（围绕 center 对称）
  Future<void> pinch(
    WidgetTester tester,
    Offset center, {
    required double fromSpread,
    required double toSpread,
  }) async {
    final g1 = await tester.startGesture(
      center - Offset(fromSpread, 0),
      pointer: 1,
    );
    final g2 = await tester.startGesture(
      center + Offset(fromSpread, 0),
      pointer: 2,
    );
    await tester.pump();
    await g1.moveTo(center - Offset(toSpread, 0));
    await g2.moveTo(center + Offset(toSpread, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();
  }

  group('时间轴双指缩放（周/日视图）', () {
    testWidgets('初始缩放级别为 64px/h', (tester) async {
      final container = makeContainer();
      await pumpCalendar(tester, container);
      expect(container.read(pixelPerHourProvider), 64.0);
    });

    testWidgets('双指张开放大 → 每小时像素高增大', (tester) async {
      final container = makeContainer();
      await pumpCalendar(tester, container);
      const center = Offset(400, 400);
      await pinch(tester, center, fromSpread: 40, toSpread: 120);
      final pp = container.read(pixelPerHourProvider);
      expect(pp, greaterThan(64.0));
    });

    testWidgets('双指捏合缩小 → 每小时像素高减小', (tester) async {
      final container = makeContainer();
      await pumpCalendar(tester, container);
      const center = Offset(400, 400);
      await pinch(tester, center, fromSpread: 80, toSpread: 20);
      final pp = container.read(pixelPerHourProvider);
      expect(pp, lessThan(64.0));
    });

    testWidgets('缩到最小 → 06:00-23:00 整屏可见', (tester) async {
      final container = makeContainer();
      await pumpCalendar(tester, container);
      // 默认缩放（64px/h）下时间轴高于视口：23:00 标签未进入构建区
      expect(tester.any(find.text('23:00')), isFalse);
      const center = Offset(400, 400);
      // 连续捏合确保缩到底（clamp 到整屏下限）
      for (var i = 0; i < 4; i++) {
        await pinch(tester, center, fromSpread: 80, toSpread: 10);
      }
      final pp = container.read(pixelPerHourProvider);
      expect(pp, greaterThan(0));
      expect(pp, lessThan(40.0));
      // 缩到底后 06:00 与 23:00 首尾标签全部进入视口
      expect(tester.any(find.text('06:00')), isTrue);
      expect(tester.any(find.text('23:00')), isTrue);
    });

    testWidgets('单指拖动滚动时间轴不改变缩放级别', (tester) async {
      final container = makeContainer();
      await pumpCalendar(tester, container);
      await tester.drag(find.byType(CalendarPage), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(container.read(pixelPerHourProvider), 64.0);
    });

    testWidgets('双指缩放不触发横向翻页', (tester) async {
      final container = makeContainer();
      await pumpCalendar(tester, container);
      final before = container.read(calendarControllerProvider).selectedDay;
      const center = Offset(400, 400);
      await pinch(tester, center, fromSpread: 40, toSpread: 140);
      final after = container.read(calendarControllerProvider).selectedDay;
      expect(
        after,
        before,
        reason: '双指缩放由 ScaleGesture 获胜，PageView 不应翻周',
      );
    });
  });
}
