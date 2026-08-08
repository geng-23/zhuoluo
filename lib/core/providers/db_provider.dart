import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';

final dbProvider = Provider<AppDatabase>((ref) => AppDatabase());

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.read(dbProvider)),
);

/// 上次自动备份失败标志（备份入口角标用，备份方案设计 3.3）。
/// 值为空串 = 无失败；非空 = 失败 JSON {time, error}。
/// 进入备份管理/自动备份成功后清除并 invalidate 本 provider。
final autoBackupFailedProvider = FutureProvider<String>((ref) async {
  final db = ref.read(dbProvider);
  return await db.getSetting(BackupService.keyAutoBackupFailed) ?? '';
});

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => ReminderScheduler(ref.read(dbProvider)),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);

/// 设置
class SettingsController {
  SettingsController(this._db);

  final AppDatabase _db;

  static const keyLastTab = 'lastTab';
  static const keySound = 'soundEnabled'; // 'true'/'false'
  static const keyHaptics = 'hapticsEnabled'; // 'true'/'false'

  Future<String?> get(String key) => _db.getSetting(key);

  Future<void> set(String key, String value) => _db.setSetting(key, value);

  Future<int> getLastTab() async =>
      int.tryParse(await get(keyLastTab) ?? '') ?? 0;

  // ---------- 音效 / 震动开关 ----------
  Future<bool> getSoundEnabled() async => (await get(keySound)) != 'false';

  Future<bool> getHapticsEnabled() async => (await get(keyHaptics)) != 'false';
}

final settingsProvider = Provider<SettingsController>(
  (ref) => SettingsController(ref.read(dbProvider)),
);

/// 主题模式全局状态（system/light/dark）
/// P3：从 profile_page 移至 core——main.dart 启动时恢复主题，
/// 此前 main 反向依赖 feature 页面文件
final themeModeProvider = StateProvider<String>((ref) => 'system');

/// 数据版本号（I3：#23 实时同步）
/// 任何数据写操作后 +1，依赖方 watch 后自动刷新
final dataVersionProvider = StateProvider<int>((ref) => 0);

/// 数据变更通知（写操作后调用）
/// 参数用 WidgetRef：同时兼容 ConsumerState/ConsumerWidget 的 ref 与 Ref
void bumpDataVersion(WidgetRef ref) {
  ref.read(dataVersionProvider.notifier).state++;
}
