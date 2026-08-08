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

  testWidgets('逐帧 pump 模拟真实帧率下 Snackbar 应消失', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();
    await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '测试任务',
      createdAt: DateTime.now(),
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

    // 完成任务
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await tester.pump();
    // 等待退出动画（250ms）完成，动作才真正执行
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget, reason: 'Snackbar 应显示');

    // 逐帧 pump 60 秒（模拟真实帧率，每帧 100ms）
    var shownAt60s = 0;
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (i == 599) {
        shownAt60s = find.text('已完成').evaluate().length;
      }
    }
    debugPrint('DIAG 逐帧60秒后 Snackbar count=$shownAt60s');
    expect(shownAt60s, 0, reason: '逐帧驱动下 Snackbar 应消失');
  });

  testWidgets('只有初始帧无后续帧时 Snackbar 不消失（模拟无VSync）', (tester) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();
    await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: '测试任务2',
      createdAt: DateTime.now(),
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

    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await tester.pump();
    // 等待退出动画完成，Snackbar 出现
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget);

    // 只推进时间但不产生新帧（模拟 VSync 停止）
    await tester.binding.delayed(const Duration(seconds: 60));
    debugPrint('DIAG 无帧60秒后 Snackbar count=${find.text('已完成').evaluate().length}');
  });
}
