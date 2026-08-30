import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/theme/task_colors.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/backup_page.dart';
import 'package:zhuoluo/features/profile/habit_page.dart';
import 'package:zhuoluo/features/profile/pomodoro_page.dart';
import 'package:zhuoluo/features/profile/preferences_page.dart';
import 'package:zhuoluo/features/profile/restore_flow.dart';
import 'package:zhuoluo/features/profile/webdav_page.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';

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
    // WebDAV 云端同步状态（入口副标题：上次同步时间 / 失败提示）
    final webdavFail = ref.watch(webdavFailedProvider).value ?? '';
    final webdavLast = ref.watch(webdavLastSyncProvider).value ?? '';
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
            _SectionGroup(
              header: const _SectionHeader('效率工具'),
              children: [
                ListTile(
                  leading: const _IconLeading(Icons.timer_outlined),
                  title: const Text('番茄专注'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(context, const PomodoroPage()),
                ),
                ListTile(
                  leading: const _IconLeading(Icons.flag_outlined),
                  title: const Text('习惯打卡'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(context, const HabitPage()),
                ),
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('统计'),
              children: [
                ListTile(
                  leading: const _IconLeading(Icons.bar_chart),
                  title: const Text('统计'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(context, const StatisticsPage()),
                ),
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('数据管理'),
              // 截图④：数据管理组统一右箭头（与其余入口一致）
              children: [
                ListTile(
                  leading: const _IconLeading(Icons.backup_outlined),
                  title: const Text('导出备份'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _export(context, ref),
                ),
                ListTile(
                    leading: _IconLeading(
                      backupFail.isEmpty
                          ? Icons.folder_open
                          : Icons.error_outline,
                      color: backupFail.isEmpty
                          ? Theme.of(context).colorScheme.primary
                          : Colors.orange,
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
                  leading: const _IconLeading(Icons.restore),
                  title: const Text('导入备份'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _import(context, ref),
                ),
                ListTile(
                  leading: _IconLeading(
                    webdavFail.isEmpty
                        ? Icons.cloud_outlined
                        : Icons.cloud_off,
                    color: webdavFail.isEmpty
                        ? Theme.of(context).colorScheme.primary
                        : Colors.orange,
                  ),
                  title: const Text('WebDAV 云备份'),
                  subtitle: webdavFail.isNotEmpty
                      ? Text(
                          '上次云端同步失败，点此查看',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade700,
                          ),
                        )
                      : Text(
                          webdavLast.isEmpty
                              ? '通过 WebDAV 把备份同步到你自己的服务器'
                              : '上次云端同步 ${_fmtWebdavTime(webdavLast)}',
                          style: AppTextStyles.subtitle(context),
                        ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(context, const WebdavPage()),
                ),
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('通知'),
              children: [
                const _NotificationPermissionTile(),
                ListTile(
                  leading: const _IconLeading(
                    Icons.notifications_active_outlined,
                  ),
                  title: const Text('发送测试通知'),
                  subtitle: Text(
                    '立即弹出一条通知，验证提醒是否正常',
                    style: AppTextStyles.subtitle(context),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _sendTestNotification(context, ref),
                ),
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('外观'),
              children: [
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
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('偏好设置'),
              children: [
                ListTile(
                  leading: const _IconLeading(Icons.tune),
                  title: const Text('偏好设置'),
                  subtitle: Text(
                    '默认清单 · 默认提醒 · 时区',
                    style: AppTextStyles.subtitle(context),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(context, const PreferencesPage()),
                ),
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('关于'),
              children: [
                ListTile(
                  leading: const _IconLeading(Icons.info_outline),
                  title: const Text('着落 v1.3.4+35'),
                  subtitle: const Text('事事有着落 · 本地数据'),
                  onTap: () => _showAbout(context),
                ),
              ],
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

  /// WebDAV 上次同步时间的入口副标题文案（MM-dd HH:mm）
  static String _fmtWebdavTime(String raw) {
    final t = DateTime.tryParse(raw);
    if (t == null) return '未知时间';
    return '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
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
      // 返回 'merge' 合并导入（按内容指纹去重），'replace' 全量替换
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('导入备份'),
          content: Text(
            '备份中有 ${stats.tasks} 个任务、${stats.lists} 个清单。\n\n'
            '「合并导入」按内容指纹去重并入当前数据'
            '（同名同内容才跳过，推荐，不丢失现有内容）；\n'
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
      // 导入与导入后的全量刷新/重排统一走共享编排
      // （replace 模式由编排内部先自动安全备份当前数据）
      await importBackupWithRefresh(
        ref,
        json,
        merge: choice == 'merge',
        safetyBackup: choice == 'replace',
      );
      if (context.mounted) {
        // 冲突增强 ③：导入完成报告
        showAppSnackBar(
          context,
          choice == 'merge'
              ? '已合并导入（按内容指纹去重）'
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

/// 我的页分组：标题 + 圆角容器包裹的列表项组
class _SectionGroup extends StatelessWidget {
  const _SectionGroup({required this.header, required this.children});

  final Widget header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(
            borderRadius: AppRadius.card,
            child: Material(
              color: scheme.surfaceContainerLow,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      Divider(
                        indent: 56,
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 14,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: AppRadius.pill,
            ),
          ),
          Text(
            title,
            style: AppTextStyles.sectionHeader(context),
          ),
        ],
      ),
    );
  }
}

/// 我的页列表图标：圆底容器 + outlined 图标（统一入口视觉）
/// [size] 默认 36（主列表行）；通知权限等 dense 行用 30
/// [color] 默认 primary；异常态（失败/未开启）传橙色保持语义
class _IconLeading extends StatelessWidget {
  const _IconLeading(this.icon, {this.size = 36, this.color});

  final IconData icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 10 / 36),
      ),
      child: Icon(icon, size: size * 20 / 36, color: c),
    );
  }
}

// ================= 通知权限中心 =================

/// 通知权限中心：通知权限 / 精确闹钟 / 电池优化 / 自启动四项，
/// 每项可一键跳对应系统设置（通知方案 A）
class _NotificationPermissionTile extends ConsumerStatefulWidget {
  const _NotificationPermissionTile();

  @override
  ConsumerState<_NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

class _NotificationPermissionTileState
    extends ConsumerState<_NotificationPermissionTile>
    with WidgetsBindingObserver {
  bool? _exactOk;
  bool? _notifOk;
  bool? _batteryOk;

  /// 跳转自启动设置后置位：回到应用（resumed）时提示用户确认
  bool _autoStartHintPending = false;

  /// 提醒渠道设置状态（声音/悬浮/振动），按渠道 ID 缓存
  final Map<String, ReminderChannelStatus?> _channelStatus = {};

  /// 提醒渠道（任务/习惯）：状态展示 + 一键跳转系统渠道设置页
  static const _reminderChannels = [
    (id: NotificationService.reminderChannelId, name: '任务提醒'),
    (id: NotificationService.habitReminderChannelId, name: '习惯提醒'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置页返回即刷新权限状态——固定延时回读在用户于系统
    // 设置停留超过延时时间时会显示旧值
    if (state == AppLifecycleState.resumed) {
      _check();
      if (_autoStartHintPending) {
        _autoStartHintPending = false;
        showAppSnackBar(
          context,
          '已打开自启动设置，请确认已允许自启动',
          icon: Icons.power_settings_new,
        );
      }
    }
  }

  Future<void> _check() async {
    final svc = ref.read(notificationServiceProvider);
    final exact = await svc.canScheduleExactAlarms();
    final notif = await svc.areNotificationsEnabled();
    final battery = await svc.isIgnoringBatteryOptimizations();
    // 提醒渠道状态：渠道属性在系统侧创建后固化，应用只能尽力默认开启，
    // 未开启的选项在下方展示并引导一键跳转开启
    final taskStatus = await svc.getReminderChannelStatus(
      NotificationService.reminderChannelId,
    );
    final habitStatus = await svc.getReminderChannelStatus(
      NotificationService.habitReminderChannelId,
    );
    // N-刷新调度权限缓存——用户从系统设置授权/拒绝后，
    // 否则调度器按旧缓存短路，提醒一直静默跳过直到重启
    await svc.refreshPermissionCache();
    if (mounted) {
      setState(() {
        _exactOk = exact;
        _notifOk = notif;
        _batteryOk = battery;
        _channelStatus[NotificationService.reminderChannelId] = taskStatus;
        _channelStatus[NotificationService.habitReminderChannelId] = habitStatus;
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
          leading: const _IconLeading(Icons.alarm, size: 30),
          title: const Text('通知权限中心'),
          subtitle: Text(
            '应用未运行时也会按时提醒（系统闹钟服务触发）',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: _check,
        ),
        // 通知权限（Android 13+）
        ListTile(
          dense: true,
          leading: _IconLeading(
            Icons.notifications_outlined,
            size: 30,
            color: notif == false
                ? Colors.orange
                : Theme.of(context).colorScheme.primary,
          ),
          title: const Text('通知权限', style: TextStyle(fontSize: 14)),
          trailing: _statusIcon(notif),
          onTap: () {
            ref.read(notificationServiceProvider).openNotificationSettings();
          },
        ),
        // 精确闹钟（Android 12+ 默认拒绝）
        ListTile(
          dense: true,
          leading: _IconLeading(
            Icons.timer_outlined,
            size: 30,
            color: exact == false
                ? Colors.orange
                : Theme.of(context).colorScheme.primary,
          ),
          title: const Text('精确闹钟权限', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '小米等厂商需在"闹钟和提醒"中允许',
            style: TextStyle(fontSize: 11),
          ),
          trailing: _statusIcon(exact),
          onTap: () {
            ref
                .read(notificationServiceProvider)
                .requestExactAlarmPermission();
          },
        ),
        // 电池优化豁免
        ListTile(
          dense: true,
          leading: _IconLeading(
            Icons.battery_saver_outlined,
            size: 30,
            color: battery == false
                ? Colors.orange
                : Theme.of(context).colorScheme.primary,
          ),
          title: const Text('电池优化豁免', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '豁免后通知更准时（建议允许）',
            style: TextStyle(fontSize: 11),
          ),
          trailing: _statusIcon(battery),
          onTap: () {
            ref
                .read(notificationServiceProvider)
                .requestBatteryOptimizationExemption();
          },
        ),
        // 自启动（HyperOS：进程被清理后系统才会恢复闹钟通知）
        ListTile(
          dense: true,
          leading: _IconLeading(
            Icons.power_settings_new,
            size: 30,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: const Text('自启动', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            'HyperOS 需允许自启动，进程被清理后系统才会恢复提醒',
            style: TextStyle(fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            // 无统一 API 查询自启动状态：跳转后靠 resumed 回调提示确认
            _autoStartHintPending = true;
            ref.read(notificationServiceProvider).openAutoStartSettings();
          },
        ),
        // 提醒渠道设置：通知声音/悬浮通知/振动默认开启（渠道创建时已尽力断言）；
        // 部分 ROM 可能未生效，此处展示真实状态并一键跳转系统对应渠道设置页
        // 引导开启。锁屏显示按系统默认，不纳入引导范围。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '提醒渠道',
            style: AppTextStyles.hint(context),
          ),
        ),
        if (_anyChannelNeedsAttention)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '声音/悬浮/振动未全部开启，点击下方渠道前往系统设置开启',
                    style: TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        for (final c in _reminderChannels) _channelTile(c.id, c.name),
      ],
    );
  }

  /// 任一提醒渠道存在未开启的关键选项（提示条展示条件）
  bool get _anyChannelNeedsAttention => _reminderChannels.any((c) {
        final s = _channelStatus[c.id];
        return s != null && s.exists && !s.allOn;
      });

  /// 提醒渠道行：状态位（声音/悬浮/振动）+ 点击跳系统渠道设置页
  Widget _channelTile(String channelId, String name) {
    final status = _channelStatus[channelId];
    final needsAttention = status != null && status.exists && !status.allOn;
    return ListTile(
      dense: true,
      leading: _IconLeading(
        Icons.campaign_outlined,
        size: 30,
        color: needsAttention
            ? Colors.orange
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text('$name渠道设置', style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        _channelStatusText(status),
        style: TextStyle(
          fontSize: 11,
          color: needsAttention
            ? Colors.orange.shade800
            : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        ref.read(notificationServiceProvider).openChannelSettings(channelId);
      },
    );
  }

  /// 渠道状态文案：null=检查中/读取失败；exists=false=无渠道机制
  String _channelStatusText(ReminderChannelStatus? s) {
    if (s == null) return '状态检查中…';
    if (!s.exists) return '渠道不存在（Android 8.0 以下无渠道机制）';
    final parts = [
      '声音 ${s.soundEnabled ? '✓' : '✗'}',
      '悬浮 ${s.floatingEnabled ? '✓' : '✗'}',
      '振动 ${s.vibrationEnabled ? '✓' : '✗'}',
    ];
    return parts.join(' · ');
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
      secondary: _IconLeading(widget.icon, size: 32),
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

/// 主题切换（跟随系统/亮/暗）+ 主题色色板选择
class _ThemeTile extends ConsumerStatefulWidget {
  const _ThemeTile();

  @override
  ConsumerState<_ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends ConsumerState<_ThemeTile> {
  String _mode = 'system';
  String _hex = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await ref.read(settingsProvider).get('themeMode');
    final c = await ref.read(settingsProvider).get('themeColor');
    if (mounted) {
      setState(() {
        _mode = v ?? 'system';
        _hex = c ?? '';
      });
    }
  }

  Color get _color => ThemePalette.fromHex(_hex);

  void _openColorSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final e in ThemePalette.colors.entries)
                _ColorDot(
                  name: e.key,
                  color: e.value,
                  selected: e.key == '默认蓝' ? _hex.isEmpty : e.value == _color,
                  onTap: () async {
                    final hex =
                        e.key == '默认蓝' ? '' : ThemePalette.toStore(e.value);
                    setState(() => _hex = hex);
                    await ref
                        .read(settingsProvider)
                        .set('themeColor', hex);
                    ref.read(themeColorProvider.notifier).state = hex;
                    if (c.mounted) Navigator.pop(c);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          leading: const _IconLeading(Icons.brightness_6_outlined),
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
        ),
        ListTile(
          leading: const _IconLeading(Icons.palette_outlined),
          title: const Text('主题色'),
          subtitle: const Text('选择一个专属主题色'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.outlineVariant,
                    width: 1,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: _openColorSheet,
        ),
      ],
    );
  }
}

/// 主题色色卡圆点（底部弹层内）
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.45),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: selected
              ? Icon(Icons.check, color: TaskColors.textOn(color))
              : null,
        ),
      ),
    );
  }
}
