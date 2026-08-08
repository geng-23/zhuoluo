import 'package:flutter/material.dart';

/// 统一提示条（撤销条/结果提示）：**新条替换旧条**，避免多个撤销条排队堆积。
/// 批量操作、频繁操作时只保留最新一条提示。
void showAppSnackBar(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  IconData icon = Icons.check,
  Duration duration = const Duration(seconds: 3),
}) {
  // A17：去抖——同一消息 400ms 内不重复弹出（连续勾选任务时旧条滑出
  // 又滑入造成闪烁）
  final now = DateTime.now();
  if (message == _lastMessage &&
      now.difference(_lastShownAt) < const Duration(milliseconds: 400)) {
    return;
  }
  _lastMessage = message;
  _lastShownAt = now;

  final scheme = Theme.of(context).colorScheme;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    // 即时替换（新条立即进入，撤销条反馈不延迟）；
    // 闪烁由上面的同消息去抖抑制
    ..removeCurrentSnackBar()
    ..showSnackBar(
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
