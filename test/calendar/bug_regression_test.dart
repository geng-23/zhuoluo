import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/main.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('日历周视图点击空白应弹出快速添加面板', (tester) async {
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

    // 切到日历 tab（默认周视图）
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    // 点击时间轴中间空白（测试窗口 800x600，时间轴从 y≈180 开始）
    await tester.tapAt(const Offset(300, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 验证快速添加面板出现（含输入框）
    expect(find.text('添加'), findsWidgets,
        reason: '点击时间轴空白应弹出快速添加面板');
  });

  testWidgets('完成任务后 Snackbar 应在 5 秒内自动消失', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();
    // 默认视图为"未来 7 天"：任务需带今天计划时段才会显示在列表中
    final start = DateTime.now();
    await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '测试任务',
      planStart: Value(start),
      planEnd: Value(start.add(const Duration(hours: 1))),
      createdAt: start,
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

    // 完成任务：点任务行左侧勾选按钮
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await tester.pump();
    // 等待退出动画（250ms）完成，动作才真正执行
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // Snackbar 出现
    expect(find.text('已完成'), findsOneWidget);

    // 对照实验1：hide+show 序列（模拟 _showUndo）
    final sm = ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first));
    sm
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          content: Text('hideShow测试'), duration: Duration(seconds: 1)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    debugPrint('DIAG hideShow测试消失=${find.text('hideShow测试').evaluate().length}');
    // 清理
    sm.clearSnackBars();
    await tester.pumpAndSettle();

    // 5 秒后应消失（动画完成后计时器才启动，需 pump 足够时长）
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    debugPrint('DIAG after 12s: 已完成 count=${find.text('已完成').evaluate().length}');
    expect(find.text('已完成'), findsNothing,
        reason: 'Snackbar 应在超时后自动消失');
  });

  testWidgets('完成动作立即执行（5.6：不再等退出动画）', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();
    // 默认视图为"未来 7 天"：任务需带今天计划时段才会显示在列表中
    final start = DateTime.now();
    final taskId = await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '动画任务',
      planStart: Value(start),
      planEnd: Value(start.add(const Duration(hours: 1))),
      createdAt: start,
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

    // 点击圆圈：真实操作立即执行（数据库 + 撤销条即时一致）
    // A17 去抖为全局静态状态 + 真实时钟：上文测试 2 刚显示过"已完成"，
    // 400ms 真实时间内再次 showAppSnackBar('已完成') 会被去抖丢弃——
    // 该测试"偶发失败"的历史根因，用真实时钟等待避开去抖窗口
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await tester.pump();
    var t = await db.getTask(taskId);
    expect(t!.completedAt, isNotNull,
        reason: '5.6：点击后数据库立即写入完成，不等动画');
    // 数据库异步 I/O 完成 + Snackbar 入场动画（与上文测试 2 同时序）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget,
        reason: '撤销条即时出现');
  });
}
