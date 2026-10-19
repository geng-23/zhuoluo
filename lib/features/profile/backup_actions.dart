import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/features/profile/restore_flow.dart';

/// 将备份导出到用户选择的位置。取消选择时静默返回。
Future<void> exportBackupFile(BuildContext context, WidgetRef ref) async {
  try {
    final path = await ref.read(backupServiceProvider).exportToUserLocation();
    if (path != null && context.mounted) {
      showAppSnackBar(context, '已导出到 $path', icon: Icons.backup_outlined);
    }
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(context, '导出失败：$e', icon: Icons.error_outline);
    }
  }
}

/// 从文件导入备份。返回 true 表示数据已变更，调用页应刷新列表。
Future<bool> importBackupFile(BuildContext context, WidgetRef ref) async {
  final service = ref.read(backupServiceProvider);
  String? json;
  try {
    json = await service.importFromUserFile();
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(context, '选择或读取备份文件失败：$e', icon: Icons.error_outline);
    }
    return false;
  }
  if (json == null || !context.mounted) return false;

  try {
    final stats = service.parseBackupStats(json);
    if (stats == null) {
      showAppSnackBar(context, '不是有效的着落备份文件', icon: Icons.error_outline);
      return false;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入备份'),
        content: Text(
          '备份中有 ${stats.tasks} 个任务、${stats.lists} 个清单。\n\n'
          '「合并导入」按内容指纹去重并入当前数据'
          '（同名同内容才跳过，推荐，不丢失现有内容）；\n'
          '「恢复并覆盖」以备份为准替换全部数据（恢复前会自动备份当前数据，'
          '可在“本地备份”中回退）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'merge'),
            child: const Text('合并导入'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'replace'),
            child: const Text('恢复并覆盖'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return false;
    await importBackupWithRefresh(
      ref,
      json,
      merge: choice == 'merge',
      safetyBackup: choice == 'replace',
    );
    if (context.mounted) {
      showAppSnackBar(
        context,
        choice == 'merge'
            ? '已合并导入（按内容指纹去重）'
            : '已恢复 ${stats.tasks} 个任务、${stats.reminders} 条提醒、'
                  '${stats.habits} 个习惯',
        icon: Icons.restore,
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(context, '恢复失败：$e', icon: Icons.error_outline);
    }
    return false;
  }
}
