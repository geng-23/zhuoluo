import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/services/backup_service.dart';
import 'package:zhuoluo/data/services/webdav_service.dart';
import 'package:zhuoluo/features/profile/restore_flow.dart';

/// WebDAV 云备份页：配置服务器 → 测试连接 → 手动/自动上传 →
/// 远端列表管理（恢复/删除）。凭据仅存本机 settings 表。
class WebdavPage extends ConsumerStatefulWidget {
  const WebdavPage({super.key});

  @override
  ConsumerState<WebdavPage> createState() => _WebdavPageState();
}

class _WebdavPageState extends ConsumerState<WebdavPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _dir = TextEditingController(text: WebdavService.defaultDir);

  bool _enabled = true;
  bool _obscurePass = true;
  bool _booting = true;
  bool _testing = false;
  bool _uploading = false;
  bool _loadingList = false;

  /// 已保存的配置（远端列表操作以已保存配置为准）
  WebdavConfig? _saved;

  List<WebdavBackupInfo> _remote = [];
  String _lastSyncAt = '';
  String _failed = '';

  BackupService get _service => ref.read(backupServiceProvider);

  /// 云端操作统一经工厂缝隙创建服务：默认真实实现，测试注入替身
  WebdavService _svc() => _service.webdavFactory?.call() ?? WebdavService();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _dir.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final cfg = await _service.readWebdavConfig();
    final lastSync =
        await ref.read(dbProvider).getSetting(BackupService.keyWebdavLastSyncAt) ??
            '';
    final failed =
        await ref.read(dbProvider).getSetting(BackupService.keyWebdavFailed) ?? '';
    if (!mounted) return;
    setState(() {
      if (cfg != null) {
        _url.text = cfg.url;
        _user.text = cfg.username;
        _pass.text = cfg.password;
        _dir.text = cfg.dir;
        _enabled = cfg.enabled;
      }
      _saved = cfg;
      _lastSyncAt = lastSync;
      _failed = failed;
      _booting = false;
    });
    if (cfg != null && cfg.connectable) {
      unawaited(_loadRemote());
    }
  }

  /// 从当前表单构造配置
  WebdavConfig _formConfig() => WebdavConfig(
        url: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        dir: _dir.text.trim(),
        enabled: _enabled,
      );

  bool get _formConnectable => _formConfig().connectable;

  Future<void> _save({required bool silent}) async {
    await _service.writeWebdavConfig(_formConfig());
    _saved = _formConfig();
    ref.invalidate(webdavLastSyncProvider);
    ref.invalidate(webdavFailedProvider);
    if (!silent && mounted) {
      showAppSnackBar(context, '已保存', icon: Icons.save_outlined);
    }
  }

  Future<void> _testConnection() async {
    if (!_formConnectable) {
      showAppSnackBar(context, '请先填写完整的服务器地址、账号和密码',
          icon: Icons.info_outline);
      return;
    }
    setState(() => _testing = true);
    try {
      // 用未保存的表单值直接测试，便于先验证再保存
      await _svc()
          .testConnection(_formConfig());
      if (mounted) showAppSnackBar(context, '连接成功', icon: Icons.cloud_done);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '$e', icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _uploadNow() async {
    if (!_formConnectable) {
      showAppSnackBar(context, '请先填写完整的服务器地址、账号和密码',
          icon: Icons.info_outline);
      return;
    }
    setState(() => _uploading = true);
    try {
      await _save(silent: true);
      final json = await _service.exportJson();
      final ok = await _service.syncToWebdav(json, requireEnabled: false);
      if (!mounted) return;
      if (ok) {
        showAppSnackBar(context, '已上传到云端', icon: Icons.cloud_upload);
        ref.invalidate(webdavLastSyncProvider);
        ref.invalidate(webdavFailedProvider);
        await _refreshStatus();
        await _loadRemote();
      } else {
        final failed = await ref
                .read(dbProvider)
                .getSetting(BackupService.keyWebdavFailed) ??
            '';
        final msg = failed.isEmpty ? '同步失败' : _failMessage(failed);
        if (mounted) showAppSnackBar(context, msg, icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String _failMessage(String raw) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final err = decoded['error'];
      if (err is String && err.isNotEmpty) return '同步失败：$err';
    } catch (_) {}
    return '同步失败';
  }

  Future<void> _refreshStatus() async {
    final db = ref.read(dbProvider);
    final lastSync =
        await db.getSetting(BackupService.keyWebdavLastSyncAt) ?? '';
    final failed = await db.getSetting(BackupService.keyWebdavFailed) ?? '';
    if (mounted) {
      setState(() {
        _lastSyncAt = lastSync;
        _failed = failed;
      });
    }
  }

  Future<void> _loadRemote() async {
    final saved = _saved;
    if (saved == null || !saved.connectable) return;
    setState(() => _loadingList = true);
    try {
      final items = await _svc()
          .list(saved);
      if (mounted) setState(() => _remote = items);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '$e', icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _restoreRemote(WebdavBackupInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复此云端备份？'),
        content: Text(
          '${info.name}\n\n'
          '恢复将替换当前全部数据。恢复前会自动备份当前数据'
          '（可在"备份管理"中回退）。',
        ),
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
    if (confirmed != true || _saved == null || !mounted) return;
    try {
      final json = await _svc().download(_saved!, info.name);
      if (!mounted) return;
      final count =
          await importBackupWithRefresh(ref, json, merge: false, safetyBackup: true);
      if (mounted) {
        showAppSnackBar(
          context,
          '已从云端恢复 $count 个任务',
          icon: Icons.restore,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '云端恢复失败：$e', icon: Icons.error_outline);
      }
    }
  }

  Future<void> _deleteRemote(WebdavBackupInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除该云端备份？'),
        content: Text(info.name),
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
    if (ok != true || _saved == null || !mounted) return;
    try {
      await _svc()
          .delete(_saved!, [info.name]);
      await _loadRemote();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '删除失败：$e', icon: Icons.error_outline);
      }
    }
  }

  String _fmtTime(DateTime t) {
    final now = AppClock.now();
    if (DateUtilsEx.sameDay(t, now)) {
      return '今天 ${DateUtilsEx.timeCn(t)}';
    }
    return '${DateUtilsEx.dateCn(t)} ${DateUtilsEx.timeCn(t)}';
  }

  String get _lastSyncLabel {
    if (_lastSyncAt.isEmpty) return '从未同步';
    final t = DateTime.tryParse(_lastSyncAt);
    return t == null ? '从未同步' : '上次同步 ${_fmtTime(t)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return Scaffold(
        appBar: AppBar(title: const Text('WebDAV 云备份')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final isHttp = _url.text.trim().startsWith('http://');
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 云备份'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新云端列表', onPressed: _loadRemote),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '服务器',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://your-server.example.com/dav/',
                    helperText: '填到 WebDAV 共享目录根路径',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (isHttp)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: Colors.orange.shade700),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '当前使用明文 HTTP，账号与数据未经加密传输，建议改用 HTTPS',
                            style: TextStyle(
                                fontSize: 12, color: Colors.orange.shade700),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '账号',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: _obscurePass,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '密码 / 应用专用密码',
                    helperText: '部分服务要求使用应用专用密码；密码仅存本机',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePass
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dir,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '远端目录',
                    helperText: '备份在云端的存放目录（可多级，如 备份/zhuoluo）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('每日自动上传'),
                  subtitle: const Text('跟随本地自动备份，每天首次打开时一并上传云端'),
                  value: _enabled,
                  onChanged: (v) {
                    setState(() => _enabled = v);
                    _save(silent: true);
                  },
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testing ? null : _testConnection,
                        icon: _testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.network_check),
                        label: const Text('测试连接'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _uploading ? null : _uploadNow,
                        icon: _uploading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.cloud_upload),
                        label: const Text('立即上传'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _failed.isEmpty
                      ? _lastSyncLabel
                      : '上次同步失败：${_failMessage(_failed)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: _failed.isEmpty
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(
                  '云端备份（${_saved == null ? '未保存配置' : '保留最近 ${BackupService.keepBackupCount} 份'}）',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_loadingList)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          if (_saved == null || !_saved!.connectable)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '填写并保存上方配置后，即可查看与管理云端备份',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            )
          else if (_remote.isEmpty && !_loadingList)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '云端暂无备份文件',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            )
          else
            for (final f in _remote)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_fmtTime(f.modified)} · ${(f.size / 1024).toStringAsFixed(1)} KB',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'restore') _restoreRemote(f);
                    if (v == 'delete') _deleteRemote(f);
                  },
                  itemBuilder: (c) => const [
                    PopupMenuItem(value: 'restore', child: Text('恢复')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                onTap: () => _restoreRemote(f),
              ),
        ],
      ),
    );
  }
}
