import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/shell/tab_swipe_detector.dart';

void main() {
  testWidgets('只有明确的横向滑动才切换主页面', (tester) async {
    var left = 0;
    var right = 0;
    const target = ValueKey('swipe-area');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabSwipeDetector(
            onSwipeLeft: () => left++,
            onSwipeRight: () => right++,
            child: const ColoredBox(
              key: target,
              color: Colors.transparent,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    await tester.timedDrag(
      find.byKey(target),
      const Offset(-110, 150),
      const Duration(milliseconds: 120),
    );
    expect(left, 0, reason: '上下为主的斜向滚动不能切换页面');

    await tester.timedDrag(
      find.byKey(target),
      const Offset(-45, 0),
      const Duration(milliseconds: 100),
    );
    expect(left, 0, reason: '短距离横扫不能切换页面');

    await tester.timedDrag(
      find.byKey(target),
      const Offset(-130, 4),
      const Duration(milliseconds: 140),
    );
    expect(left, 1);

    await tester.timedDrag(
      find.byKey(target),
      const Offset(130, 4),
      const Duration(milliseconds: 140),
    );
    expect(right, 1);
  });
}
