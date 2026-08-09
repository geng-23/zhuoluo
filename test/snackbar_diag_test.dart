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

  testWidgets('诊断 SnackBar timer 条件', (tester) async {
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

    // 完成任务触发 Snackbar
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
    await tester.pump();
    // 等待退出动画完成，Snackbar 出现
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget);

    // 逐帧推进并记录 Snackbar 位置（修复后 Snackbar 应在 5 秒后消失）
    var disappeared = false;
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('已完成').evaluate().isEmpty) {
        disappeared = true;
        debugPrint('DIAG 消失于 t=${(i + 1) * 100}ms');
        break;
      }
    }
    debugPrint('DIAG 5秒内消失=$disappeared');
    expect(disappeared, isTrue, reason: '带 action 的 SnackBar 应 5 秒后自动消失');
    // 再推进确认不回来
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('DIAG 7s后 snackbar count=${find.text('已完成').evaluate().length}');

    // 诊断：TickerMode / 路由状态 / ScaffoldMessenger build 条件
    final smElement = tester.element(find.byType(ScaffoldMessenger).first);
    final tickerMode = TickerMode.valuesOf(smElement).enabled;
    final route = ModalRoute.of(smElement);
    debugPrint('DIAG tickerModeEnabled=$tickerMode');
    debugPrint('DIAG routeIsCurrent=${route?.isCurrent} routeIsFirst=${route?.isFirst}');

    // 检查 SnackBar widget 是否还在树上
    debugPrint('DIAG snackbar text count=${find.text('已完成').evaluate().length}');

    // 再推进 60 秒看是否消失
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('DIAG 60s后 snackbar count=${find.text('已完成').evaluate().length}');
  });

  testWidgets('对照：极简 ScaffoldMessenger 下 Snackbar 应消失', (tester) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: key,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  key.currentState!.showSnackBar(const SnackBar(
                    content: Text('极简测试'),
                    duration: Duration(seconds: 1),
                  ));
                },
                child: const Text('显示'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('显示'));
    await tester.pump();
    expect(find.text('极简测试'), findsOneWidget);

    // 逐帧推进 60 秒
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('DIAG 极简60s后 count=${find.text('极简测试').evaluate().length}');
    expect(find.text('极简测试'), findsNothing, reason: '极简环境 Snackbar 应消失');
  });
}
