import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/features/profile/backup_page.dart';
import 'package:zhuoluo/features/profile/habit_page.dart';
import 'package:zhuoluo/features/profile/pomodoro_page.dart';
import 'package:zhuoluo/features/profile/preferences_page.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// 我的页：工具入口 + 设置
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, this.onNavigateLeft});

  /// 空白处左滑时回调（切换四象限 tab）
  final VoidCallback? onNavigateLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 备份方案设计 3.3：自动备份失败 → 备份入口角标提示（不弹窗打扰）
    final backupFail = ref.watch(autoBackupFailedProvider).value ?? '';
    final failTime = _parseAutoBackupFailTime(backupFail);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      // 空白处从左向右滑切四象限（翻页式：上一个 tab；列表垂直滚动不冲突）
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v > 300) {
            onNavigateLeft?.call();
          }
        },
        child: ListView(
          // 截图③：底部留足 Tab Bar 高度，列表项/副标题不被遮挡
          padding: const EdgeInsets.only(bottom: 140),
          children: [
            const _SectionHeader('效率工具'),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('番茄专注'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(context, const PomodoroPage()),
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('习惯打卡'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(context, const HabitPage()),
            ),
            const Divider(),
            const _SectionHeader('统计'),
            ListTile(
              leading: const Icon(Icons.bar_chart),
              title: const Text('统计'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(context, const StatisticsPage()),
            ),
            const Divider(),
            const _SectionHeader('数据管理'),
            // 截图④：数据管理组统一右箭头（与其余入口一致）
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('导出备份'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _export(context, ref),
            ),
            ListTile(
                leading: Icon(
                  backupFail.isEmpty
                      ? Icons.folder_open
                      : Icons.error_outline,
                  color: backupFail.isEmpty ? null : Colors.orange,
                ),
                title: const Text('备份管理'),
                subtitle: backupFail.isEmpty
                    ? null
                    : Text(
                        '上次自动备份失败（$failTime），点此查看',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade700,
                        ),
                      ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  // 进入备份管理页后清除失败标志（备份方案设计 3.3）
                  await _clearAutoBackupFailed(ref);
                  if (context.mounted) {
                    _push(context, const BackupManagePage());
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('导入备份'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _import(context, ref),
            ),
            const Divider(),
            const _SectionHeader('通知'),
            const _NotificationPermissionTile(),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('发送测试通知'),
              subtitle: Text(
                '立即弹出一条通知，验证提醒是否正常',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _sendTestNotification(context, ref),
            ),
            const Divider(),
            const _SectionHeader('外观'),
            const _ThemeTile(),
            const _FeedbackTile(
              icon: Icons.music_note_outlined,
              title: '音效',
              settingKey: SettingsController.keySound,
              loadValue: _loadSound,
              applyValue: _applySound,
            ),
            const _FeedbackTile(
              icon: Icons.vibration,
              title: '震动',
              settingKey: SettingsController.keyHaptics,
              loadValue: _loadHaptics,
              applyValue: _applyHaptics,
            ),
            const Divider(),
            const _SectionHeader('偏好设置'),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('偏好设置'),
              subtitle: Text(
                '默认清单 · 默认提醒 · 时区',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(context, const PreferencesPage()),
            ),
            const Divider(),
            const _SectionHeader('关于'),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('着落 v1.2.3+24'),
              subtitle: const Text('事事有着落 · 本地数据'),
              onTap: () => _showAbout(context),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 解析 autoBackupFailed JSON 中的失败时间（MM-dd HH:mm）
  static String _parseAutoBackupFailTime(String raw) {
    if (raw.isEmpty) return '';
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final t = DateTime.tryParse(data['time'] as String? ?? '');
      if (t == null) return '未知时间';
      return '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')} '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '未知时间';
    }
  }

  /// 清除自动备份失败标志（进入备份管理页时调用）
  static Future<void> _clearAutoBackupFailed(WidgetRef ref) async {
    await ref.read(dbProvider).setSetting(BackupService.keyAutoBackupFailed, '');
    ref.invalidate(autoBackupFailedProvider);
  }

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('着落'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('一款让事事有着落的本地待办应用：任务、日历、四象限，数据全部保存在设备上。'),
            SizedBox(height: 16),
            Text('联系方式：confusion_geng@protonmail.com'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final service = ref.read(backupServiceProvider);
    try {
      // 方案 A：系统保存对话框（默认下载目录，文件名预填）——
      // 备份存放在用户选定位置，卸载 App 不丢失
      final path = await service.exportToUserLocation();
      if (path == null) return; // 用户取消
      if (context.mounted) {
        // Android 返回展示路径（Download/着落/文件名），
        // 其余平台为用户选择的完整路径
        showAppSnackBar(context, '已导出到 $path', icon: Icons.backup_outlined);
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          '导出失败：$e',
          icon: Icons.error_outline,
        );
      }
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final service = ref.read(backupServiceProvider);
    final db = ref.read(dbProvider);
    // 方案 A：系统打开对话框，从任意位置选择备份 JSON
    // （分段 try：选择/读取失败与导入失败分开提示，便于定位）
    String? json;
    try {
      json = await service.importFromUserFile();
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          '选择或读取备份文件失败：$e',
          icon: Icons.error_outline,
        );
      }
      return;
    }
    if (json == null) return; // 用户取消
    if (!context.mounted) return;
    try {
      // 校验并统计备份内容
      final stats = service.parseBackupStats(json);
      if (stats == null) {
        showAppSnackBar(
          context,
          '不是有效的着落备份文件',
          icon: Icons.error_outline,
        );
        return;
      }
      // 确认框：替换 / 合并两种导入方式（备份方案设计 3.4）
      // 返回 'merge' 合并导入（按标题去重），'replace' 全量替换
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('导入备份'),
          content: Text(
            '备份中有 ${stats.tasks} 个任务、${stats.lists} 个清单。\n\n'
            '「合并导入」按标题去重并入当前数据（推荐，不丢失现有内容）；\n'
            '「恢复并覆盖」以备份为准替换全部数据（恢复前会自动备份当前数据，'
            '可在"备份管理"中回退）。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, null),
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
      if (choice == null || !context.mounted) return;
      if (choice == 'replace') {
        // 冲突增强 ①：导入前自动安全备份当前数据（文档目录，备份管理可回退）
        await service.exportToFile(toDownloads: false);
        if (context.mounted) {
          showAppSnackBar(
            context,
            '已自动备份当前数据（可在备份管理中回退）',
            icon: Icons.backup_outlined,
          );
        }
      }
      await service.importJson(json, merge: choice == 'merge');
      await db.ensureDefaultList();
      // B4：恢复后全量刷新任务控制器（重载清单/任务）
      await ref.read(tasksControllerProvider.notifier).init();
      // 恢复后 bump 数据版本（四象限/日历/统计常驻页同步刷新）
      bumpDataVersion(ref);
      // 重载备份中的内存态设置（主题/音效/震动，此前需重启才生效）
      await reloadRuntimeSettings(db, ref);
      // 恢复成功后自动全量重排通知（rescheduleAll 先取消全部旧通知
      // 再按新数据排期；不再依赖用户选择"稍后"导致通知状态不一致）
      await ref.read(reminderSchedulerProvider).rescheduleAll();
      if (context.mounted) {
        // 冲突增强 ③：导入完成报告
        showAppSnackBar(
          context,
          choice == 'merge'
              ? '已合并导入（按标题去重）'
              : '已恢复 ${stats.tasks} 个任务、${stats.reminders} 条提醒、'
                  '${stats.habits} 个习惯',
          icon: Icons.restore,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          '恢复失败：$e',
          icon: Icons.error_outline,
        );
      }
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

// ================= 通知权限中心 =================

/// 通知权限中心：通知权限 / 精确闹钟 / 电池优化三项状态，
/// 每项可一键跳对应系统设置（通知方案 A）
class _NotificationPermissionTile extends ConsumerStatefulWidget {
  const _NotificationPermissionTile();

  @override
  ConsumerState<_NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

class _NotificationPermissionTileState
    extends ConsumerState<_NotificationPermissionTile> {
  bool? _exactOk;
  bool? _notifOk;
  bool? _batteryOk;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final svc = ref.read(notificationServiceProvider);
    final exact = await svc.canScheduleExactAlarms();
    final notif = await svc.areNotificationsEnabled();
    final battery = await svc.isIgnoringBatteryOptimizations();
    // N-刷新调度权限缓存——用户从系统设置授权/拒绝后，
    // 否则调度器按旧缓存短路，提醒一直静默跳过直到重启
    await svc.refreshPermissionCache();
    if (mounted) {
      setState(() {
        _exactOk = exact;
        _notifOk = notif;
        _batteryOk = battery;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final exact = _exactOk;
    final notif = _notifOk;
    final battery = _batteryOk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.alarm),
          title: const Text('通知权限中心'),
          subtitle: Text(
            '应用未运行时也会按时提醒（系统闹钟服务触发）',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
            ),
          ),
          onTap: _check,
        ),
        // 通知权限（Android 13+）
        ListTile(
          dense: true,
          leading: Icon(
            Icons.notifications_outlined,
            size: 20,
            color: notif == false ? Colors.orange : Colors.grey.shade600,
          ),
          title: const Text('通知权限', style: TextStyle(fontSize: 14)),
          trailing: _statusIcon(notif),
          onTap: () async {
            await ref
                .read(notificationServiceProvider)
                .openNotificationSettings();
            Future.delayed(const Duration(seconds: 1), _check);
          },
        ),
        // 精确闹钟（Android 12+ 默认拒绝）
        ListTile(
          dense: true,
          leading: Icon(
            Icons.timer_outlined,
            size: 20,
            color: exact == false ? Colors.orange : Colors.grey.shade600,
          ),
          title: const Text('精确闹钟权限', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '小米等厂商需在"闹钟和提醒"中允许',
            style: TextStyle(fontSize: 11),
          ),
          trailing: _statusIcon(exact),
          onTap: () async {
            await ref
                .read(notificationServiceProvider)
                .requestExactAlarmPermission();
            Future.delayed(const Duration(seconds: 1), _check);
          },
        ),
        // 电池优化豁免
        ListTile(
          dense: true,
          leading: Icon(
            Icons.battery_saver_outlined,
            size: 20,
            color: battery == false ? Colors.orange : Colors.grey.shade600,
          ),
          title: const Text('电池优化豁免', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '豁免后通知更准时（建议允许）',
            style: TextStyle(fontSize: 11),
          ),
          trailing: _statusIcon(battery),
          onTap: () async {
            await ref
                .read(notificationServiceProvider)
                .requestBatteryOptimizationExemption();
            Future.delayed(const Duration(seconds: 1), _check);
          },
        ),
      ],
    );
  }

  /// 状态图标：null=检查中 / true=已开启 / false=未开启
  Widget _statusIcon(bool? ok) {
    if (ok == null) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return ok
        ? Icon(Icons.check_circle, color: Colors.green.shade400, size: 20)
        : const Icon(Icons.chevron_right);
  }
}

/// 发送测试通知（通知方案 A）
Future<void> _sendTestNotification(BuildContext context, WidgetRef ref) async {
  final svc = ref.read(notificationServiceProvider);
  final ok = await svc.sendTestNotification();
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    ok ? '测试通知已发送，1 秒后到达' : '通知发送失败：请检查上方权限状态',
    icon: ok ? Icons.notifications_active_outlined : Icons.error_outline,
  );
}

// ================= 音效 / 震动开关 =================
Future<bool> _loadSound(SettingsController s) async {
  final v = await s.getSoundEnabled();
  SoundService.soundsEnabled = v;
  return v;
}

void _applySound(SettingsController s, bool v) {
  SoundService.soundsEnabled = v;
}

Future<bool> _loadHaptics(SettingsController s) async {
  final v = await s.getHapticsEnabled();
  Haptics.hapticsEnabled = v;
  return v;
}

void _applyHaptics(SettingsController s, bool v) {
  Haptics.hapticsEnabled = v;
}

/// 音效/震动开关（设置持久化 + 即时生效）
class _FeedbackTile extends ConsumerStatefulWidget {
  const _FeedbackTile({
    required this.icon,
    required this.title,
    required this.settingKey,
    required this.loadValue,
    required this.applyValue,
  });

  final IconData icon;
  final String title;
  final String settingKey;
  final Future<bool> Function(SettingsController) loadValue;
  final void Function(SettingsController, bool) applyValue;

  @override
  ConsumerState<_FeedbackTile> createState() => _FeedbackTileState();
}

class _FeedbackTileState extends ConsumerState<_FeedbackTile> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsProvider);
    final v = await widget.loadValue(settings);
    if (mounted) setState(() => _on = v);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(widget.icon),
      title: Text(widget.title),
      value: _on,
      onChanged: (v) async {
        setState(() => _on = v);
        final settings = ref.read(settingsProvider);
        await settings.set(widget.settingKey, '$v');
        widget.applyValue(settings, v);
        // 切换反馈：音效开关开启时出声，震动开关开启时震动（关闭状态自然静默）
        SoundService.instance.play(SoundKind.click);
        Haptics.select();
      },
    );
  }
}

/// 主题切换（跟随系统/亮/暗）
class _ThemeTile extends ConsumerStatefulWidget {
  const _ThemeTile();

  @override
  ConsumerState<_ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends ConsumerState<_ThemeTile> {
  String _mode = 'system';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await ref.read(settingsProvider).get('themeMode');
    if (mounted) setState(() => _mode = v ?? 'system');
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: const Text('主题模式'),
      trailing: DropdownButton<String>(
        value: _mode,
        underline: const SizedBox.shrink(),
        items: const [
          DropdownMenuItem(value: 'system', child: Text('跟随系统')),
          DropdownMenuItem(value: 'light', child: Text('亮色')),
          DropdownMenuItem(value: 'dark', child: Text('暗色')),
        ],
        onChanged: (v) async {
          if (v == null) return;
          setState(() => _mode = v);
          await ref.read(settingsProvider).set('themeMode', v);
          ref.read(themeModeProvider.notifier).state = v;
        },
      ),
    );
  }
}
