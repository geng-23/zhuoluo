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
import 'package:zhuoluo/features/profile/backup_page.dart';
import 'package:zhuoluo/features/profile/habit_page.dart';
import 'package:zhuoluo/features/profile/pomodoro_page.dart';
import 'package:zhuoluo/features/profile/preferences_page.dart';
import 'package:zhuoluo/features/statistics/statistics_page.dart';
import 'package:zhuoluo/shell/tab_swipe_detector.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      // 空白处从左向右滑切四象限（翻页式：上一个 tab；列表垂直滚动不冲突）
      body: TabSwipeDetector(
        onSwipeRight: onNavigateLeft,
        child: ListView(
          // 截图③：底部留足 Tab Bar 高度，列表项/副标题不被遮挡
          padding: const EdgeInsets.only(bottom: 140),
          children: [
            _SectionGroup(
              header: const _SectionHeader('功能'),
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
                ListTile(
                  leading: const _IconLeading(Icons.bar_chart),
                  title: const Text('统计'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(context, const StatisticsPage()),
                ),
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('数据'),
              children: [
                ListTile(
                  leading: _IconLeading(
                    backupFail.isEmpty && webdavFail.isEmpty
                        ? Icons.folder_open
                        : Icons.error_outline,
                    color: backupFail.isEmpty && webdavFail.isEmpty
                        ? Theme.of(context).colorScheme.primary
                        : Colors.orange,
                  ),
                  title: const Text('备份与恢复'),
                  subtitle: Text(
                    backupFail.isNotEmpty
                        ? '上次自动备份失败（$failTime）'
                        : webdavFail.isNotEmpty
                        ? '上次云端同步失败'
                        : '导出、导入、本地备份与 WebDAV',
                    style: AppTextStyles.subtitle(context),
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
              ],
            ),
            _SectionGroup(
              header: const _SectionHeader('提醒'),
              children: [const _ReminderSettingsTile()],
            ),
            _SectionGroup(
              header: const _SectionHeader('设置'),
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
                  title: const Text('着落 v1.0.0+1'),
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
    await ref
        .read(dbProvider)
        .setSetting(BackupService.keyAutoBackupFailed, '');
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
          Text(title, style: AppTextStyles.sectionHeader(context)),
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

/// 提醒设置：精确闹钟与自启动。
class _ReminderSettingsTile extends ConsumerStatefulWidget {
  const _ReminderSettingsTile();

  @override
  ConsumerState<_ReminderSettingsTile> createState() =>
      _ReminderSettingsTileState();
}

class _ReminderSettingsTileState extends ConsumerState<_ReminderSettingsTile>
    with WidgetsBindingObserver {
  bool? _exactAlarmEnabled;
  bool _autoStartHintPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkExactAlarmPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _checkExactAlarmPermission();
    if (_autoStartHintPending) {
      _autoStartHintPending = false;
      showAppSnackBar(
        context,
        '已打开自启动设置，请确认已允许自启动',
        icon: Icons.power_settings_new,
      );
    }
  }

  Future<void> _checkExactAlarmPermission() async {
    final enabled = await ref
        .read(notificationServiceProvider)
        .canScheduleExactAlarms();
    if (mounted) setState(() => _exactAlarmEnabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const _IconLeading(Icons.alarm_outlined),
          title: const Text('精确闹钟'),
          subtitle: Text(_statusText(_exactAlarmEnabled)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => ref
              .read(notificationServiceProvider)
              .requestExactAlarmPermission(),
        ),
        ListTile(
          leading: const _IconLeading(Icons.power_settings_new),
          title: const Text('自启动'),
          subtitle: Text(
            '允许自启动，以便系统在后台恢复提醒',
            style: AppTextStyles.subtitle(context),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            _autoStartHintPending = true;
            ref.read(notificationServiceProvider).openAutoStartSettings();
          },
        ),
      ],
    );
  }

  String _statusText(bool? enabled) => switch (enabled) {
    true => '已开启',
    false => '未开启，点此打开系统设置',
    null => '检查中…',
  };
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
                    final hex = e.key == '默认蓝'
                        ? ''
                        : ThemePalette.toStore(e.value);
                    setState(() => _hex = hex);
                    await ref.read(settingsProvider).set('themeColor', hex);
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
                  border: Border.all(color: scheme.outlineVariant, width: 1),
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
