import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/main.dart';

/// Snackbar 生命周期测试：自动消失时序（真实帧率驱动 / 无 VSync 场景）
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester, {required String title}) async {
    await db.ensureDefaultList();
    final def = await db.getDefaultList();
    await db.insertTask(TasksCompanion.insert(
      listId: def.id,
      title: title,
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
    // 跨测试去抖：showAppSnackBar 全局记录上一条消息（400ms 去抖窗口），
    // 前一个测试刚显示过"已完成"时本条会被吞掉——runAsync 真实等待越过去抖
    //（testWidgets 的 fake 时钟下 Future.delayed 不会真实推进）
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await tester.pump();
    // 等待退出动画（250ms）完成，动作才真正执行
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget, reason: 'Snackbar 应显示');
  }

  testWidgets('带撤销动作的 Snackbar 应在 5 秒后自动消失', (tester) async {
    await pumpApp(tester, title: '测试任务');
    var disappeared = false;
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('已完成').evaluate().isEmpty) {
        disappeared = true;
        break;
      }
    }
    expect(disappeared, isTrue, reason: '带 action 的 SnackBar 应 5 秒后自动消失');
    // 再推进确认不回来
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('已完成'), findsNothing, reason: '消失后不复发');
  });

  testWidgets('逐帧 pump 模拟真实帧率下 Snackbar 应消失', (tester) async {
    await pumpApp(tester, title: '测试任务A');
    var shownAt60s = 0;
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (i == 599) {
        shownAt60s = find.text('已完成').evaluate().length;
      }
    }
    expect(shownAt60s, 0, reason: '逐帧驱动下 Snackbar 应消失');
  });

  testWidgets('只有初始帧无后续帧时 Snackbar 不消失（模拟无 VSync）', (tester) async {
    await pumpApp(tester, title: '测试任务B');
    // 只推进时间但不产生新帧（模拟 VSync 停止）
    await tester.binding.delayed(const Duration(seconds: 60));
    expect(find.text('已完成'), findsOneWidget,
        reason: '无新帧时 Snackbar 不应消失（等待 VSync 驱动计时器）');
  });
}
