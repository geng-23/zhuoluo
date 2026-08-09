import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/backup_types.dart';
import 'package:zhuoluo/features/task/providers.dart';

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
    final now = AppClock.now();
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
      // + 备份方案设计 3.5：恢复前自动安全备份当前数据（私有目录），
      // 恢复失败/不满意时可从备份管理回退
      await service.exportToFile(toDownloads: false);
      final json = await service.readFile(path);
      await service.importJson(json);
      await db.ensureDefaultList();
      // B4：恢复后全量刷新任务控制器
      await ref.read(tasksControllerProvider.notifier).init();
      // 恢复后 bump 数据版本（四象限/日历/统计常驻页同步刷新）
      bumpDataVersion(ref);
      // 重载备份中的内存态设置（主题/音效/震动）
      await reloadRuntimeSettings(db, ref);
      // 恢复成功后自动全量重排通知（先取消旧通知再按新数据排期）
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

/// 备份恢复后重载内存态设置（主题/音效/震动/应用时区）
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
