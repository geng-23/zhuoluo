import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// 备份导入/恢复共用编排（本地文件导入、备份管理恢复、WebDAV 云端恢复
/// 三处共用，避免各页面复制粘贴漂移）：
///
/// 1. 覆盖模式（merge = false）且 [safetyBackup] 为真时，先把当前数据
///    自动安全备份到私有目录（可在"备份管理"回退）
/// 2. 执行导入（单事务原子）
/// 3. ensureDefaultList → 刷新任务控制器 → bump 数据版本
///    → 重载内存态设置（主题/音效/震动/应用时区）→ 全量重排提醒
///
/// 返回导入的任务数；异常向上抛出，由调用方统一提示。
Future<int> importBackupWithRefresh(
  WidgetRef ref,
  String json, {
  required bool merge,
  bool safetyBackup = false,
}) async {
  final service = ref.read(backupServiceProvider);
  final db = ref.read(dbProvider);
  if (!merge && safetyBackup) {
    await service.exportToFile(toDownloads: false);
  }
  final count = await service.importJson(json, merge: merge);
  await db.ensureDefaultList();
  // 恢复后全量刷新任务控制器（重载清单/任务）
  await ref.read(tasksControllerProvider.notifier).init();
  // bump 数据版本（四象限/日历/统计常驻页同步刷新）
  bumpDataVersion(ref);
  await reloadRuntimeSettings(db, ref);
  // 全量重排通知（先取消旧通知再按新数据排期，保证通知与数据一致）
  await ref.read(reminderSchedulerProvider).rescheduleAll();
  return count;
}

/// 备份恢复后重载内存态设置（主题/音效/震动/应用时区）。
/// 恢复导入的 settings 含 themeMode/soundEnabled/hapticsEnabled/appTimezone，
/// 此前只在启动时加载，恢复后需重启才生效。
Future<void> reloadRuntimeSettings(AppDatabase db, WidgetRef ref) async {
  final savedTheme = await db.getSetting('themeMode');
  if (savedTheme != null && savedTheme.isNotEmpty) {
    ref.read(themeModeProvider.notifier).state = savedTheme;
  }
  final settings = ref.read(settingsProvider);
  SoundService.soundsEnabled = await settings.getSoundEnabled();
  Haptics.hapticsEnabled = await settings.getHapticsEnabled();
  // 偏好设置组：恢复备份后同步应用时区（内存态）。
  // 全量重排由调用方（导入/恢复流程）在 reloadRuntimeSettings 之后执行
  AppClock.setTimezone(await settings.getAppTimezone());
}
