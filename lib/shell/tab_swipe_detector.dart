import 'package:flutter/material.dart';

/// 主页面切换手势：要有足够横向位移，且横向明显多于纵向。
/// 子页面的滚动、任务卡片滑动仍由各自手势识别器参与竞争。
class TabSwipeDetector extends StatefulWidget {
  const TabSwipeDetector({
    super.key,
    required this.child,
    this.onSwipeLeft,
    this.onSwipeRight,
  });

  final Widget child;
  final VoidCallback? onSwipeLeft;
  final VoidCallback? onSwipeRight;

  @override
  State<TabSwipeDetector> createState() => _TabSwipeDetectorState();
}

class _TabSwipeDetectorState extends State<TabSwipeDetector> {
  Offset? _start;
  Offset? _latest;

  void _reset() {
    _start = null;
    _latest = null;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onHorizontalDragDown: (details) {
      _start = details.globalPosition;
      _latest = details.globalPosition;
    },
    onHorizontalDragUpdate: (details) => _latest = details.globalPosition,
    onHorizontalDragCancel: _reset,
    onHorizontalDragEnd: (details) {
      final start = _start;
      final latest = _latest;
      _reset();
      if (start == null || latest == null) return;
      final dx = latest.dx - start.dx;
      final dy = latest.dy - start.dy;
      final speed = details.primaryVelocity ?? 0;
      if (dx.abs() < 80 || dx.abs() < dy.abs() * 1.7) return;
      if (speed.abs() < 300 && dx.abs() < 160) return;
      if (dx > 0 && speed >= 0) widget.onSwipeRight?.call();
      if (dx < 0 && speed <= 0) widget.onSwipeLeft?.call();
    },
    child: widget.child,
  );
}
