import 'package:flutter/material.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 统一提示条（撤销条/结果提示）：**新条替换旧条**，避免多个撤销条排队堆积。
/// 批量操作、频繁操作时只保留最新一条提示。
void showAppSnackBar(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  IconData icon = Icons.check,
  Duration duration = const Duration(seconds: 3),
  /// 抬高到底部 FAB 之上（列表页完成/撤销等高频操作时，
  /// 此前撤销条遮住 FAB 一半，露出上半截很突兀）
  bool aboveFab = false,
}) {
  // A17：去抖——同一消息 400ms 内不重复弹出（连续勾选任务时旧条滑出
  // 又滑入造成闪烁）
  final now = AppClock.now();
  if (message == _lastMessage &&
      now.difference(_lastShownAt) < const Duration(milliseconds: 400)) {
    return;
  }
  _lastMessage = message;
  _lastShownAt = now;

  final scheme = Theme.of(context).colorScheme;
  final messenger = ScaffoldMessenger.of(context);
  // 撤销条（actionLabel 非空）替换旧条优先显示；普通提示不顶掉现有条
  //（排队等待）——避免"今天已跳过"等提示移除撤销入口，导致
  // 跳过/改期撤销失效
  if (actionLabel != null) {
    // 即时替换（新条立即进入，撤销条反馈不延迟）；闪烁由同消息去抖抑制
    messenger.removeCurrentSnackBar();
  }
  messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onPrimaryContainer),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        duration: duration,
        persist: false,
        behavior: SnackBarBehavior.floating,
        margin: aboveFab ? const EdgeInsets.fromLTRB(16, 0, 16, 76) : null,
        backgroundColor: scheme.inverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        action: actionLabel == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                textColor: scheme.primary,
                onPressed: onAction ?? () {},
              ),
      ),
    );
}

String? _lastMessage;
DateTime _lastShownAt = DateTime.fromMillisecondsSinceEpoch(0);
