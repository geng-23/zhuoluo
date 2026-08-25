import 'package:flutter/material.dart';

/// 统一的"完成勾选"图标：未完成空心圈 ↔ 已完成实心勾，
/// 状态切换时轻微回弹缩放 + 淡入过渡。
/// 全应用唯一实现，替代此前任务列表/详情/习惯/日历弹层各自的写法
/// （含小图标上过冲明显的 elasticOut），统一曲线与时长
class DoneCheckIcon extends StatelessWidget {
  const DoneCheckIcon({
    super.key,
    required this.done,
    this.size = 20,
    this.doneColor,
    this.undoneColor,
  });

  final bool done;
  final double size;
  /// 已完成态颜色，默认 colorScheme.primary
  final Color? doneColor;
  /// 未完成态颜色，默认 colorScheme.onSurfaceVariant
  final Color? undoneColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      // easeOutBack：受控的轻微回弹（约 1.1 倍），替代 elasticOut 的
      // 多次震荡抖动；出场用 easeOut 快速让位
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: Icon(
        done ? Icons.check_circle : Icons.radio_button_unchecked,
        key: ValueKey(done),
        size: size,
        color: done
            ? (doneColor ?? scheme.primary)
            : (undoneColor ?? scheme.onSurfaceVariant),
      ),
    );
  }
}
