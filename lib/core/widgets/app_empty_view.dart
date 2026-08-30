import 'package:flutter/material.dart';

/// 全局空状态视图：图标 + 主文案 + 副文案 + 可选行动按钮
/// 任务页 / 回收站 / 习惯 / 备份页统一复用（同一设计语言）
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.icon,
    this.title,
    this.subtitle,
    this.action,
    this.actions,
  });

  final IconData icon;
  /// 主文案（null 则不显示）
  final String? title;
  /// 副文案（null 则不显示）
  final String? subtitle;
  /// 待办里的主要行动按钮（如“添加第一个任务”）
  final Widget? action;
  /// 附加行动（如搜索态“清除搜索”）
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 44,
                color: scheme.primary,
              ),
            ),
            if (title != null) ...[
              const SizedBox(height: 16),
              Text(
                title!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
            if (actions != null) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: actions!),
            ],
          ],
        ),
      ),
    );
  }
}
