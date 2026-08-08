import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' show Value;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/backup_types.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';

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
            const _SectionHeader('关于'),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('着落 v1.0.0'),
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
      // P1-A：恢复后 bump 数据版本（四象限/日历/统计常驻页同步刷新）
      bumpDataVersion(ref);
      // P1-A：重载备份中的内存态设置（主题/音效/震动，此前需重启才生效）
      await _reloadRuntimeSettings(db, ref);
      // P0-3.7：恢复成功后自动全量重排通知（rescheduleAll 先取消全部旧通知
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

/// H2：#30 备份管理页（列出/删除单份/多份/全部/恢复）
class BackupManagePage extends ConsumerStatefulWidget {
  const BackupManagePage({super.key});

  @override
  ConsumerState<BackupManagePage> createState() => _BackupManagePageState();
}

class _BackupManagePageState extends ConsumerState<BackupManagePage> {
  List<BackupFileInfo> _files = [];
  bool _loading = true;
  final Set<String> _selected = {};
  bool _multiSelect = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(backupServiceProvider);
    final files = await service.listBackupInfos();
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份管理'),
        actions: [
          if (_multiSelect)
            IconButton(
              icon: Icon(
                _selected.length == _files.length
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              tooltip: '全选',
              onPressed: () {
                setState(() {
                  if (_selected.length == _files.length) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(_files.map((f) => f.path));
                  }
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
          ? const Center(
              child: Text('暂无备份文件', style: TextStyle(color: Colors.grey)),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (context, i) {
                      final f = _files[i];
                      final selected = _selected.contains(f.path);
                      return ListTile(
                        leading: _multiSelect
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) => _toggle(f.path),
                              )
                            : const Icon(Icons.description_outlined),
                        title: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_fmtTime(f.modified)} · ${(f.size / 1024).toStringAsFixed(1)} KB',
                        ),
                        trailing: _multiSelect
                            ? null
                            : PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'restore') {
                                    _restore(f.path);
                                  } else if (v == 'delete') {
                                    _deleteSingle(f.path);
                                  }
                                },
                                itemBuilder: (c) => const [
                                  PopupMenuItem(
                                    value: 'restore',
                                    child: Text('恢复'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除'),
                                  ),
                                ],
                              ),
                        onLongPress: () {
                          setState(() {
                            _multiSelect = true;
                            _selected.add(f.path);
                          });
                        },
                        onTap: () {
                          if (_multiSelect) {
                            _toggle(f.path);
                          }
                        },
                      );
                    },
                  ),
                ),
                if (_multiSelect)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Text('已选 ${_selected.length} 份'),
                          const Spacer(),
                          TextButton(
                            onPressed: _selected.isEmpty
                                ? null
                                : () => _deleteSelected(),
                            child: Text(
                              '删除所选',
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _deleteAll(),
                            child: Text(
                              '删除全部',
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              _multiSelect = false;
                              _selected.clear();
                            }),
                            child: const Text('完成'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) {
        _selected.remove(path);
        if (_selected.isEmpty) _multiSelect = false;
      }
    });
  }

  String _fmtTime(DateTime t) {
    final now = DateTime.now();
    if (DateUtilsEx.sameDay(t, now)) {
      return '今天 ${DateUtilsEx.timeCn(t)}';
    }
    return '${DateUtilsEx.dateCn(t)} ${DateUtilsEx.timeCn(t)}';
  }

  Future<void> _restore(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复此备份？'),
        content: const Text('恢复将替换当前全部数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final service = ref.read(backupServiceProvider);
    final db = ref.read(dbProvider);
    try {
      // P1-5 + 备份方案设计 3.5：恢复前自动安全备份当前数据（私有目录），
      // 恢复失败/不满意时可从备份管理回退
      await service.exportToFile(toDownloads: false);
      final json = await service.readFile(path);
      await service.importJson(json);
      await db.ensureDefaultList();
      // B4：恢复后全量刷新任务控制器
      await ref.read(tasksControllerProvider.notifier).init();
      // P1-A：恢复后 bump 数据版本（四象限/日历/统计常驻页同步刷新）
      bumpDataVersion(ref);
      // P1-A：重载备份中的内存态设置（主题/音效/震动）
      await _reloadRuntimeSettings(db, ref);
      // P0-3.7：恢复成功后自动全量重排通知（先取消旧通知再按新数据排期）
      await ref.read(reminderSchedulerProvider).rescheduleAll();
      if (mounted) {
        showAppSnackBar(context, '恢复完成', icon: Icons.restore);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          '恢复失败：$e',
          icon: Icons.error_outline,
        );
      }
    }
  }

  Future<void> _deleteSingle(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除该备份？'),
        content: Text(path.split('/').last),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(backupServiceProvider).deleteBackupFiles([path]);
      _load();
    }
  }

  Future<void> _deleteSelected() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除所选备份？'),
        content: Text('将删除 ${_selected.length} 份备份文件'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref
          .read(backupServiceProvider)
          .deleteBackupFiles(_selected.toList());
      setState(() {
        _multiSelect = false;
        _selected.clear();
      });
      _load();
    }
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除全部备份？'),
        content: Text('将删除全部 ${_files.length} 份备份文件'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('全部删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref
          .read(backupServiceProvider)
          .deleteBackupFiles(_files.map((f) => f.path).toList());
      setState(() {
        _multiSelect = false;
        _selected.clear();
      });
      _load();
    }
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
    // N-P1-1：刷新调度权限缓存——用户从系统设置授权/拒绝后，
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

// ================= 番茄专注 =================

/// P1-A：备份恢复后重载内存态设置（主题/音效/震动）
/// 恢复导入的 settings 含 themeMode/soundEnabled/hapticsEnabled，
/// 此前只在启动时加载，恢复后需重启才生效。
Future<void> _reloadRuntimeSettings(AppDatabase db, WidgetRef ref) async {
  final savedTheme = await db.getSetting('themeMode');
  if (savedTheme != null && savedTheme.isNotEmpty) {
    ref.read(themeModeProvider.notifier).state = savedTheme;
  }
  final settings = ref.read(settingsProvider);
  SoundService.soundsEnabled = await settings.getSoundEnabled();
  Haptics.hapticsEnabled = await settings.getHapticsEnabled();
}

/// 番茄钟状态：未开始 / 计时中 / 已暂停
enum _PomodoroState { idle, running, paused }

class PomodoroPage extends ConsumerStatefulWidget {
  const PomodoroPage({super.key});

  @override
  ConsumerState<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends ConsumerState<PomodoroPage> {
  int _minutes = 25;
  _PomodoroState _state = _PomodoroState.idle;
  int _remaining = 25 * 60;
  int? _taskId;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() {
      _state = _PomodoroState.running;
      _remaining = _minutes * 60;
    });
    SoundService.instance.play(SoundKind.add);
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _remaining--;
        if (_remaining <= 0) {
          _finish();
        }
      });
    });
  }

  void _pause() {
    _timer?.cancel();
    setState(() => _state = _PomodoroState.paused);
    SoundService.instance.play(SoundKind.reopen);
  }

  void _resume() {
    setState(() => _state = _PomodoroState.running);
    SoundService.instance.play(SoundKind.reopen);
    _startTimer();
  }

  /// 放弃当前进度，从头计时
  void _restart() {
    _timer?.cancel();
    setState(() {
      _state = _PomodoroState.running;
      _remaining = _minutes * 60;
    });
    SoundService.instance.play(SoundKind.add);
    _startTimer();
  }

  /// 结束（含提前结束）：记录实际专注时长
  Future<void> _finish() async {
    _timer?.cancel();
    final elapsedSec = _minutes * 60 - _remaining;
    // P1-4.8：立即结束（elapsedSec <= 0）记录 0 分钟
    // （此前会把完整 15/25/45 分钟记进统计）
    final elapsedMin = elapsedSec <= 0
        ? 0
        : (elapsedSec / 60).ceil().clamp(1, _minutes);
    setState(() {
      _state = _PomodoroState.idle;
      // 恢复显示待开始时长（而非 00:00）
      _remaining = _minutes * 60;
    });
    // P1-4.8：数据库保存成功后再显示成功反馈
    // P2：捕获外键异常（关联任务被删除时 insertPomodoro 抛错，此前无反馈）
    try {
      await ref.read(dbProvider).insertPomodoro(
        _taskId,
        elapsedMin,
        DateTime.now().subtract(Duration(minutes: elapsedMin)),
      );
      // P1-A：番茄记录写库后通知统计等依赖方
      bumpDataVersion(ref);
    } catch (e) {
      debugPrint('番茄记录保存失败: $e');
      if (!mounted) return;
      showAppSnackBar(
        context,
        '专注记录保存失败：${_taskId != null ? '关联任务可能已删除' : e}',
        icon: Icons.error_outline,
      );
      return;
    }
    if (!mounted) return;
    SoundService.instance.play(SoundKind.complete);
    Haptics.medium();
    showAppSnackBar(
      context,
      elapsedMin == 0 ? '专注已结束' : '专注完成（$elapsedMin 分钟）',
      icon: Icons.timer_outlined,
    );
  }

  Future<void> _pickTask() async {
    // P2：关联任务改为全量未完成任务（此前 take(30) 且依赖当前视图——
    // "今天"视图下无法关联未来的计划任务）
    final db = ref.read(dbProvider);
    final tasks = await db.getAllUncompleted();
    if (!mounted) return;
    // -1 = 不关联，null = 取消
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              dense: true,
              title: Text(
                '关联任务',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: Icon(
                _taskId == null
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: _taskId == null
                    ? Theme.of(c).colorScheme.primary
                    : Colors.grey.shade400,
              ),
              title: const Text('不关联任务'),
              onTap: () => Navigator.pop(c, -1),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in tasks)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        _taskId == t.id
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: _taskId == t.id
                            ? Theme.of(c).colorScheme.primary
                            : Colors.grey.shade400,
                      ),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(c, t.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null) {
      setState(() => _taskId = selected == -1 ? null : selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    final tasks = ref.watch(tasksControllerProvider).tasks;
    final linked = _taskId == null
        ? null
        : tasks.where((t) => t.id == _taskId).firstOrNull;
    final canEdit = _state == _PomodoroState.idle;
    return Scaffold(
      appBar: AppBar(title: const Text('番茄专注')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$_minutes 分钟',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          Text(
            '$mm:$ss',
            style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final m in [15, 25, 45])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text('$m 分'),
                    selected: _minutes == m,
                    onSelected: canEdit
                        ? (v) => setState(() {
                              _minutes = m;
                              // C3-2：空闲态切换时长同步倒计时显示
                              // （此前选"45 分"大数字仍显示 25:00）
                              _remaining = m * 60;
                            })
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          // 按状态显示操作按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: switch (_state) {
              _PomodoroState.idle => [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 40,
                      vertical: 16,
                    ),
                  ),
                  onPressed: _start,
                ),
              ],
              _PomodoroState.running => [
                FilledButton.icon(
                  icon: const Icon(Icons.pause),
                  label: const Text('暂停'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 16,
                    ),
                  ),
                  onPressed: _pause,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('结束'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 16,
                    ),
                  ),
                  onPressed: _finish,
                ),
              ],
              _PomodoroState.paused => [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('继续'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 16,
                    ),
                  ),
                  onPressed: _resume,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.replay),
                  label: const Text('重新开始'),
                  onPressed: _restart,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('结束'),
                  onPressed: _finish,
                ),
              ],
            },
          ),
          const SizedBox(height: 24),
          // 关联任务（卡片式选择器）
          if (tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: canEdit ? _pickTask : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.link, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            linked?.title ?? '关联任务（可选）',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: linked == null
                                  ? Colors.grey.shade600
                                  : null,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: Colors.grey.shade400,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ================= 习惯打卡 =================

class HabitPage extends ConsumerStatefulWidget {
  const HabitPage({super.key, this.initialHabitId});

  /// 5.4：通知点击深链定位的目标习惯（滚动到该项并高亮）
  final int? initialHabitId;

  @override
  ConsumerState<HabitPage> createState() => _HabitPageState();
}

class _HabitPageState extends ConsumerState<HabitPage> {
  List<Habit> _habits = [];
  bool _loading = true;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final habits = await db.getHabits();
    if (mounted) {
      setState(() {
        _habits = habits;
        _loading = false;
      });
    }
    // 5.4：通知点击定位到具体习惯（滚动到该项）
    final targetId = widget.initialHabitId;
    if (targetId != null) {
      final idx = habits.indexWhere((h) => h.id == targetId);
      if (idx >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          _scroll.jumpTo(
            (idx * 72.0).clamp(0.0, _scroll.position.maxScrollExtent),
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('习惯打卡')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addHabit,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _habits.isEmpty
          ? const Center(
              child: Text('还没有习惯，点 + 添加', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              controller: _scroll,
              itemExtent: 72,
              itemCount: _habits.length,
              itemBuilder: (context, index) {
                final habit = _habits[index];
                return _HabitTile(
                  habit: habit,
                  highlight: habit.id == widget.initialHabitId,
                  onRefresh: _load,
                  onDelete: () async {
                    // P2：删除习惯前确认（此前直接删除，误触即丢打卡记录）
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('删除习惯？'),
                        content: Text(
                          '「${habit.name}」及其全部打卡记录将被删除',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: Text(
                              '删除',
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    final db = ref.read(dbProvider);
                    // 先取消已排的每日提醒，避免删除后仍收到通知
                    await ref
                        .read(reminderSchedulerProvider)
                        .cancelHabitReminder(habit.id);
                    await db.deleteHabit(habit.id);
                    // P1-A：习惯数据变更通知
                    bumpDataVersion(ref);
                    _load();
                  },
                );
              },
            ),
    );
  }

  Future<void> _addHabit() async {
    final controller = TextEditingController();
    var remind = false;
    var time = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
      9,
      0,
    );
    final draft = await showDialog<_HabitDraft>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: const Text('新建习惯'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: '如：阅读、健身、早睡'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('每日提醒'),
                value: remind,
                onChanged: (v) => setDialogState(() => remind = v),
              ),
              if (remind)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule, size: 20),
                  title: Text('提醒时间 ${DateUtilsEx.timeCn(time)}'),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(time),
                    );
                    if (picked != null) {
                      setDialogState(
                        () => time = DateTime(
                          time.year,
                          time.month,
                          time.day,
                          picked.hour,
                          picked.minute,
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                _HabitDraft(controller.text.trim(), remind ? time : null),
              ),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (draft != null && draft.name.isNotEmpty) {
      final db = ref.read(dbProvider);
      final id = await db.insertHabit(draft.name, '⭐', draft.reminderTime);
      // P1-A：习惯数据变更通知
      bumpDataVersion(ref);
      if (draft.reminderTime != null) {
        final habit = await db.getHabit(id);
        if (habit != null) {
          // P1-4.9：提醒未成功排入系统时提示
          final ok = await ref
              .read(reminderSchedulerProvider)
              .scheduleHabitReminder(habit);
          if (!ok && mounted) {
            showAppSnackBar(
              context,
              '提醒未成功排入系统：请检查通知权限',
              icon: Icons.notifications_off_outlined,
            );
          }
        }
      }
      _load();
    }
  }
}

/// 新建习惯草稿（名称 + 提醒时间）
class _HabitDraft {
  final String name;
  final DateTime? reminderTime;

  _HabitDraft(this.name, this.reminderTime);
}

class _HabitTile extends ConsumerStatefulWidget {
  const _HabitTile({
    required this.habit,
    required this.onRefresh,
    required this.onDelete,
    this.highlight = false,
  });

  final Habit habit;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;
  /// 5.4：通知深链定位时高亮该习惯
  final bool highlight;

  @override
  ConsumerState<_HabitTile> createState() => _HabitTileState();
}

class _HabitTileState extends ConsumerState<_HabitTile> {
  bool _doneToday = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final done = await db.isHabitDone(widget.habit.id, DateTime.now());
    if (mounted) setState(() => _doneToday = done);
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    final remindText = widget.habit.reminderTime == null
        ? null
        : '每日 ${DateUtilsEx.timeCn(widget.habit.reminderTime!)} 提醒';
    return ListTile(
      tileColor: widget.highlight
          ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      leading: CircleAvatar(
        backgroundColor: _doneToday
            ? Theme.of(context).colorScheme.primary
            : null,
        child: Text(widget.habit.icon),
      ),
      title: Text(widget.habit.name),
      subtitle: Text(
        _doneToday
            ? '今日已打卡${remindText == null ? '' : ' · $remindText'}'
            : (remindText ?? '今日未打卡'),
        style: TextStyle(
          color: _doneToday
              ? Theme.of(context).colorScheme.primary
              : Colors.grey,
        ),
      ),
      trailing: IconButton(
        icon: Icon(
          _doneToday ? Icons.check_circle : Icons.radio_button_unchecked,
          color: _doneToday ? Theme.of(context).colorScheme.primary : null,
        ),
        onPressed: () async {
          // 批4-4：习惯打卡补触觉反馈（此前无）
          Haptics.light();
          // P2：打卡/取消打卡都是 toggle 语义，带撤销条（误触可恢复）
          final willDone = !_doneToday;
          await db.checkHabit(widget.habit.id, DateTime.now());
          // P1-A：习惯打卡数据变更通知
          bumpDataVersion(ref);
          _load();
          if (!context.mounted) return;
          showAppSnackBar(
            context,
            willDone ? '已打卡「${widget.habit.name}」' : '已取消今日打卡',
            actionLabel: '撤销',
            onAction: () async {
              await db.checkHabit(widget.habit.id, DateTime.now());
              bumpDataVersion(ref);
              _load();
            },
            icon: willDone ? Icons.check_circle_outline : Icons.undo,
          );
        },
      ),
      onLongPress: () => _showActions(),
    );
  }

  void _showActions() {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('设置提醒'),
              onTap: () {
                Navigator.pop(c);
                _editReminder();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('删除习惯', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(c);
                widget.onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑习惯提醒时间（开关 + 时间选择）
  Future<void> _editReminder() async {
    final habit = widget.habit;
    var remind = habit.reminderTime != null;
    var time =
        habit.reminderTime ??
        DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
          9,
          0,
        );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: const Text('习惯提醒'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('每日提醒'),
                value: remind,
                onChanged: (v) => setDialogState(() => remind = v),
              ),
              if (remind)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule, size: 20),
                  title: Text('提醒时间 ${DateUtilsEx.timeCn(time)}'),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(time),
                    );
                    if (picked != null) {
                      setDialogState(
                        () => time = DateTime(
                          time.year,
                          time.month,
                          time.day,
                          picked.hour,
                          picked.minute,
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final db = ref.read(dbProvider);
    final scheduler = ref.read(reminderSchedulerProvider);
    await db.updateHabitReminder(habit.id, remind ? time : null);
    // P1-A：习惯数据变更通知
    bumpDataVersion(ref);
    final updated = await db.getHabit(habit.id);
    if (updated != null) {
      // P1-4.9：提醒未成功排入系统时提示
      final ok = await scheduler.scheduleHabitReminder(updated);
      if (!ok && mounted) {
        showAppSnackBar(
          context,
          '提醒未成功排入系统：请检查通知权限',
          icon: Icons.notifications_off_outlined,
        );
      }
    }
    widget.onRefresh();
  }
}

// ================= 四象限 =================

class QuadrantPage extends ConsumerStatefulWidget {
  const QuadrantPage({super.key, this.onNavigateLeft, this.onNavigateRight});

  /// 空白处左滑（切日历）/ 右滑（切我的）
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateRight;

  @override
  ConsumerState<QuadrantPage> createState() => _QuadrantPageState();
}

class _QuadrantPageState extends ConsumerState<QuadrantPage> {
  List<Task> _tasks = [];
  bool _loading = true;
  /// P2：数据版本订阅句柄（dispose 时 close，防泄漏）
  late final ProviderSubscription<int> _dataSub;

  @override
  void initState() {
    super.initState();
    // B1：四象限固定显示全部未完成任务（不随当前 smartView/清单变化）；
    // 数据版本变化（任务增删改完成）自动刷新
    _dataSub = ref.listenManual<int>(dataVersionProvider, (prev, next) {
      if (prev != next) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _dataSub.close();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final tasks = await db.getAllUncompleted();
    if (mounted) {
      setState(() {
        _tasks = tasks;
        _loading = false;
      });
    }
  }

  /// C7-2：展开未分类任务列表（可完成/拖动归类）
  void _showUnclassified(List<Task> tasks, TasksController notifier) {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '未分类任务',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in tasks)
                    ListTile(
                      dense: true,
                      leading: IconButton(
                        icon: const Icon(Icons.radio_button_unchecked, size: 20),
                        onPressed: () async {
                          await notifier.completeTask(t.id);
                          if (c.mounted) Navigator.pop(c);
                          _load();
                        },
                      ),
                      title: Text(t.title, maxLines: 1),
                      onTap: () {
                        Navigator.pop(c);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TaskDetailPage(taskId: t.id),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(tasksControllerProvider.notifier);
    final cells = <int, List<Task>>{for (var i = 0; i < 4; i++) i: []};
    // P1-4：未分类任务（quadrant 默认 4）不再静默塞进"一般"象限，
    // 单独计数并提示归类
    final unclassified = <Task>[];
    for (final t in _tasks) {
      if (t.quadrant < 0 || t.quadrant > 3) {
        unclassified.add(t);
      } else {
        cells[t.quadrant]!.add(t);
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('四象限')),
      // 空白处左右滑导航（翻页式：从左向右滑=上一个 tab=日历，从右向左滑=下一个 tab=我的）
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
              // opaque：空象限（无任务）时空白区域也能触发切 tab
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: (details) {
                final v = details.primaryVelocity ?? 0;
                if (v > 300) {
                  widget.onNavigateLeft?.call();
                } else if (v < -300) {
                  widget.onNavigateRight?.call();
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    if (unclassified.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          // C7-2：横幅可点击展开未分类任务列表
                          // （此前提示"长按拖动"但任务不可见、无法操作）
                          onTap: () => _showUnclassified(unclassified, notifier),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.label_off_outlined,
                                  size: 18,
                                  color: Colors.grey.shade600,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${unclassified.length} 个任务未分类，点击查看',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    for (final row in [
                      [0, 1],
                      [2, 3],
                    ])
                      Expanded(
                        child: Row(
                          children: [
                            for (final q in row)
                              Expanded(
                                child: _QuadrantCell(
                                  quadrant: q,
                                  tasks: cells[q]!,
                                  onTaskComplete: (t) async {
                                    await notifier.completeTask(t.id);
                                    if (!context.mounted) return;
                                    // 完成撤销条（与任务页同款浮动圆角卡片）
                                    showAppSnackBar(
                                      context,
                                      '已完成',
                                      actionLabel: '撤销',
                                      onAction: () =>
                                          notifier.reopenTask(t.id),
                                    );
                                  },
                                  // G1：拖入切换象限
                                  onTaskDropped: (taskId) async {
                                    SoundService.instance.play(
                                      SoundKind.drop,
                                    );
                                    Haptics.light();
                                    await notifier.updateTaskFields(
                                      taskId,
                                      TasksCompanion(quadrant: Value(q)),
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _QuadrantCell extends StatelessWidget {
  const _QuadrantCell({
    required this.quadrant,
    required this.tasks,
    required this.onTaskComplete,
    required this.onTaskDropped,
  });

  final int quadrant;
  final List<Task> tasks;
  final ValueChanged<Task> onTaskComplete;
  final ValueChanged<int> onTaskDropped;

  @override
  Widget build(BuildContext context) {
    final color = quadrantColors[quadrant];
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onTaskDropped(details.data),
      builder: (context, candidate, _) => Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: candidate.isNotEmpty
              ? color.withValues(alpha: 0.25)
              : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: candidate.isNotEmpty ? color : color.withValues(alpha: 0.4),
            width: candidate.isNotEmpty ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    quadrantNames[quadrant],
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${tasks.length}',
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: tasks.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.drag_indicator,
                            size: 28,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '拖任务到这里',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (context, i) {
                        final t = tasks[i];
                        // A5：任务首次出现（如从其他象限拖入）时放大回弹
                        return TweenAnimationBuilder<double>(
                          key: ValueKey('quad-enter-${t.id}'),
                          tween: Tween(begin: 0.6, end: 1.0),
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutBack,
                          builder: (context, v, child) =>
                              Transform.scale(scale: v, child: child),
                          child: LongPressDraggable<int>(
                            data: t.id,
                            onDragStarted: () => Haptics.select(),
                            feedback: Material(
                              color: Colors.transparent,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  t.title,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                            childWhenDragging: Opacity(
                              opacity: 0.3,
                              child: _quadrantTaskTile(context, t),
                            ),
                            child: _quadrantTaskTile(context, t),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quadrantTaskTile(BuildContext context, Task t) {
    final color = quadrantColors[quadrant];
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: t.id)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              InkWell(
                onTap: () => onTaskComplete(t),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Icon(
                    Icons.radio_button_unchecked,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (t.planStart != null)
                      Text(
                        DateUtilsEx.dateCn(t.planStart!),
                        style: const TextStyle(fontSize: 11),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.drag_indicator,
                size: 18,
                color: color.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
