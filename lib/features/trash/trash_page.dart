import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/trash/trash_providers.dart';

/// 回收站：已删除任务整棵树快照，支持恢复/彻底删除/清空，超期自动清理。
class TrashPage extends ConsumerStatefulWidget {
  const TrashPage({super.key});

  @override
  ConsumerState<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends ConsumerState<TrashPage> {
  bool _multiSelect = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    // 打开时清理超期条目（保留期来自偏好设置）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final retention = await ref.read(trashRetentionDaysProvider.future);
      final cutoff = AppClock.now().subtract(Duration(days: retention));
      await ref.read(tasksControllerProvider.notifier).purgeExpiredTrash(cutoff);
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _selected.clear();
    });
  }

  Future<void> _restore(TrashItem item) async {
    final notifier = ref.read(tasksControllerProvider.notifier);
    await notifier.restoreFromTrash(item.id);
    if (!mounted) return;
    _exitMultiSelect();
    showAppSnackBar(
      context,
      '已恢复「${item.title}」',
      actionLabel: '撤销',
      // 撤销恢复 = 再次移入回收站（原任务仍存在，重新走删除快照）
      onAction: () async {
        await notifier.deleteTaskWithUndo(item.originalTaskId);
      },
      icon: Icons.restore,
    );
  }

  Future<void> _purge(TrashItem item, {bool multi = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('彻底删除？'),
        content: Text('「${item.title}」将从回收站彻底删除，无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              '彻底删除',
              style: TextStyle(color: Theme.of(c).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(tasksControllerProvider.notifier).purgeTrashItem(item.id);
    if (mounted) {
      if (multi) {
        _selected.remove(item.id);
        if (_selected.isEmpty) _exitMultiSelect();
      }
      showAppSnackBar(
        context,
        '已彻底删除「${item.title}」',
        icon: Icons.delete_forever_outlined,
      );
    }
  }

  Future<void> _batchRestore() async {
    final ids = _selected.toList();
    _exitMultiSelect();
    await ref.read(tasksControllerProvider.notifier).batchRestoreFromTrash(ids);
    if (mounted) {
      showAppSnackBar(
        context,
        '已恢复 ${ids.length} 个任务',
        icon: Icons.restore,
      );
    }
  }

  Future<void> _batchPurge() async {
    final ids = _selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('彻底删除所选？'),
        content: Text('将彻底删除 ${ids.length} 个任务，无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              '彻底删除',
              style: TextStyle(color: Theme.of(c).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _exitMultiSelect();
    final notifier = ref.read(tasksControllerProvider.notifier);
    for (final id in ids) {
      await notifier.purgeTrashItem(id);
    }
    if (mounted) {
      showAppSnackBar(
        context,
        '已彻底删除 ${ids.length} 个任务',
        icon: Icons.delete_forever_outlined,
      );
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空回收站？'),
        content: const Text('将彻底删除回收站中的全部任务，无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              '清空',
              style: TextStyle(color: Theme.of(c).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(tasksControllerProvider.notifier).clearTrash();
    if (mounted) {
      showAppSnackBar(
        context,
        '已清空回收站',
        icon: Icons.delete_sweep_outlined,
      );
    }
  }

  void _showItemActions(TrashItem item) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '删除于 ${_formatTime(item.deletedAt)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              dense: true,
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('恢复任务'),
              onTap: () {
                Navigator.pop(c);
                _restore(item);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(c).colorScheme.error,
              ),
              title: Text(
                '彻底删除',
                style: TextStyle(color: Theme.of(c).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(c);
                _purge(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime d) {
    final a = AppClock.asApp(d);
    return '${DateUtilsEx.dateCn(a)} ${DateUtilsEx.timeCn(a)}';
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(trashItemsProvider);
    final retentionAsync = ref.watch(trashRetentionDaysProvider);
    final items = itemsAsync.valueOrNull ?? const <TrashItem>[];
    // 列表变化时清空失效选择（被恢复/删除的条目）
    ref.listen<AsyncValue<List<TrashItem>>>(trashItemsProvider, (prev, next) {
      final fresh = next.valueOrNull;
      if (fresh == null) return;
      final ids = fresh.map((i) => i.id).toSet();
      if (_selected.any((id) => !ids.contains(id))) {
        setState(() => _selected.removeWhere((id) => !ids.contains(id)));
      }
    });

    final retention = retentionAsync.valueOrNull ?? 30;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          if (_multiSelect)
            IconButton(
              icon: const Icon(Icons.restore),
              tooltip: '恢复所选',
              onPressed: _batchRestore,
            ),
          if (_multiSelect)
            IconButton(
              icon: const Icon(Icons.delete_forever_outlined),
              tooltip: '彻底删除所选',
              onPressed: _batchPurge,
            ),
          if (_multiSelect)
            IconButton(
              icon: Icon(
                _selected.length == items.length
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              tooltip: '全选',
              onPressed: () {
                setState(() {
                  if (_selected.length == items.length) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(items.map((i) => i.id));
                  }
                });
              },
            ),
          if (_multiSelect)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消',
              onPressed: _exitMultiSelect,
            ),
          if (!_multiSelect && items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空回收站',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: itemsAsync.isLoading && items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? _EmptyTrash()
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  color: scheme.surfaceContainerLow,
                  child: Text(
                    '超过 $retention 天的条目将自动清理',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        leading: _multiSelect
                            ? Checkbox(
                                value: _selected.contains(item.id),
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selected.add(item.id);
                                    } else {
                                      _selected.remove(item.id);
                                    }
                                  });
                                },
                              )
                            : Icon(
                                Icons.delete_outline,
                                color: scheme.onSurfaceVariant,
                              ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${item.listName} · 删除于 ${_formatTime(item.deletedAt)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: _multiSelect
                            ? null
                            : const Icon(Icons.more_vert),
                        selected: _selected.contains(item.id),
                        onLongPress: () {
                          setState(() {
                            _multiSelect = true;
                            _selected.add(item.id);
                          });
                        },
                        onTap: _multiSelect
                            ? () {
                                setState(() {
                                  if (_selected.contains(item.id)) {
                                    _selected.remove(item.id);
                                    if (_selected.isEmpty) {
                                      _multiSelect = false;
                                    }
                                  } else {
                                    _selected.add(item.id);
                                  }
                                });
                              }
                            : () => _showItemActions(item),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _EmptyTrash extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.delete_outline,
            size: 64,
            color: scheme.outline.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 12),
          Text(
            '回收站为空',
            style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '删除的任务会先进入这里，可恢复或彻底删除',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}
