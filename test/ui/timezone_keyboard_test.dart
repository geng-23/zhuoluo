import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/profile/preferences_page.dart';

/// 时区选择弹层键盘避让回归测试（HCI-7 模式）：
/// 搜索时软键盘弹起，弹层随 viewInsets 抬升，结果列表不被键盘遮挡、
/// 不延伸到屏幕最下方。修复前弹层钉在屏幕底边，下半部分被键盘盖住。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('时区搜索：键盘弹起时结果列表底边位于键盘上沿之上', (tester) async {
    await db.ensureDefaultList();
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PreferencesPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 打开时区弹层
    await tester.tap(find.text('应用时区'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // 聚焦搜索框，模拟键盘弹出（物理像素 1200 = 逻辑 400，默认测试 DPR 3.0）
    await tester.showKeyboard(find.byType(TextField));
    const keyboardPhysical = 1200.0;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardPhysical);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Asia');
    await tester.pumpAndSettle();

    // 搜索结果已渲染
    expect(find.text('Asia/Shanghai'), findsOneWidget);

    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final keyboard = keyboardPhysical / tester.view.devicePixelRatio;
    final scrollView = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(SingleChildScrollView),
    );
    // 键盘弹起时，弹层内容底边不得低于键盘上沿（修复前为屏高，被键盘遮挡）
    final rect = tester.getRect(scrollView);
    expect(
      rect.bottom,
      lessThanOrEqualTo(logicalHeight - keyboard + 0.5),
      reason: '键盘弹起时弹层内容底边应位于键盘上沿之上（HCI-7 键盘避让）',
    );

    // 键盘收起后弹层恢复贴底布局（不回归 85% 屏高上限行为）
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    final rect2 = tester.getRect(scrollView);
    expect(
      rect2.bottom,
      greaterThan(logicalHeight - keyboard),
      reason: '键盘收起后弹层应恢复贴底布局',
    );
  });
}
