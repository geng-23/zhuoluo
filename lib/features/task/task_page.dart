import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/core/utils/task_ext.dart';
import 'package:zhuoluo/core/utils/task_title.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart' hide TimeOfDay;
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';
import 'package:zhuoluo/features/trash/trash_page.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/widgets/app_empty_view.dart';
import 'package:zhuoluo/core/widgets/done_check_icon.dart';
import 'package:zhuoluo/core/widgets/parse_hint_text_field.dart';

/// 任务页：抽屉侧栏 + 任务列表
class TaskPage extends ConsumerStatefulWidget {
  const TaskPage({super.key, this.onNavigateNext});

  /// 空白处右滑时回调（切换日历 tab）
  final VoidCallback? onNavigateNext;

  @override
  ConsumerState<TaskPage> createState() => _TaskPageState();
}

class _TaskPageState extends ConsumerState<TaskPage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _multiSelect = false;
  final Set<int> _selected = {};
  /// 5.5：空白区导航手势累计位移（防快速轻扫误触）
  double _navDragDx = 0;
  /// 搜索模式（AppBar 内嵌搜索框）
  bool _searchMode = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 进入搜索模式（保留当前词可编辑；不清空——清空会触发 reload，
  /// 被 build 同步逻辑立即反掉导致"点了没反应"）
  void _enterSearchMode() {
    setState(() => _searchMode = true);
  }

  /// 退出搜索模式并清空搜索词（回到"全部"）
  void _exitSearchMode() {
    _searchMode = false;
    ref.read(tasksControllerProvider.notifier).clearSearch();
  }

  /// 任务是否已完成（重复任务 = 今天实例完成状态）
  bool _isDone(Task t) {
    if (t.rrule.isNotEmpty) {
      return ref.read(tasksControllerProvider).instanceDone[t.id] ?? false;
    }
    return t.completedAt != null;
  }

  /// 完成/撤销当前实例（5.6：立即写库并出撤销条，
  /// 不再等退出动画——此前动画期间界面/数据库/撤销条短暂不一致）
  Future<void> _toggleComplete(Task t) async {
    final notifier = ref.read(tasksControllerProvider.notifier);
    // 重复任务今天不是规则日 → 无"今天实例"可完成（防止写入
    // 不存在的实例记录，如周二完成周一/三的任务）
    if (t.rrule.isNotEmpty) {
      final todayHas =
          ref.read(tasksControllerProvider).todayHas[t.id] ?? false;
      if (!todayHas) {
        showAppSnackBar(
          context,
          '今天没有「${t.title}」的实例',
          icon: Icons.event_busy,
        );
        return;
      }
    }
    if (_isDone(t)) {
      await notifier.reopenTask(t.id);
      if (mounted) {
        _showUndo(
          '已恢复未完成',
          () => notifier.completeTask(t.id),
          icon: Icons.undo,
        );
      }
    } else {
      // C1-2：用返回的实际实例日期提示（未来系列完成的是计划日实例，
      // 界面"今天"状态不变，必须明确告知写入的是哪天）
      final doneDay = await notifier.completeTask(t.id);
      if (mounted) {
        if (t.rrule.isNotEmpty && doneDay != null) {
          final isFuture = DateUtilsEx.sameDay(
                doneDay,
                AppClock.now(),
              ) ==
              false;
          _showUndo(
            isFuture
                ? '已提前完成 ${DateUtilsEx.dateCn(doneDay)} 的实例'
                : '已完成 ${DateUtilsEx.dateCn(doneDay)} 的实例',
            () => notifier.reopenTask(t.id),
          );
        } else {
          _showUndo('已完成', () => notifier.reopenTask(t.id));
        }
      }
    }
  }

  /// 删除任务（5.6：立即删除并出撤销条；重复任务先弹选择框）
  Future<void> _deleteTask(Task t) async {
    final notifier = ref.read(tasksControllerProvider.notifier);
    // 重复任务：删除本次（跳过实例）/ 删除全部（整个系列）
    if (t.rrule.isNotEmpty) {
      final instDay = TasksController.currentInstanceDate(t);
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('删除重复任务'),
          content: Text(
            '要删除哪个？\n\n'
            '「${t.title}」\n'
            '· 删除本次（${DateUtilsEx.dateCn(instDay)}）：仅跳过这一天\n'
            '· 删除全部：删除整个系列并移入回收站，可恢复',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, 'skip'),
              child: const Text('删除本次'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, 'all'),
              child: Text('删除全部', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      );
      if (choice == 'skip') {
        await notifier.skipInstance(t.id, instDay);
        if (mounted) {
          _showUndo(
            '已跳过 ${DateUtilsEx.dateCn(instDay)} 的实例',
            () => notifier.unskipInstance(t.id, instDay),
            icon: Icons.skip_next,
          );
        }
      } else if (choice == 'all') {
        await notifier.deleteTaskWithUndo(t.id);
        if (mounted) {
          _showUndo(
            '已删除「${t.title}」整个系列',
            () => notifier.undoDelete(t.id),
            icon: Icons.delete_outline,
          );
        }
      }
      return;
    }
    await notifier.deleteTaskWithUndo(t.id);
    if (mounted) {
      _showUndo(
        '已删除「${t.title}」',
        () => notifier.undoDelete(t.id),
        icon: Icons.delete_outline,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(tasksControllerProvider);
    // 搜索修复：搜索词被外部清空（抽屉切换视图等）→ 自动退出搜索模式。
    // 用 build 中 ref.listen 监听"非空 → 空"的转变，避免进入模式瞬间
    // （query 本就为空）被误退出
    ref.listen<TasksState>(tasksControllerProvider, (prev, next) {
      if (prev != null &&
          prev.searchQuery.isNotEmpty &&
          next.searchQuery.isEmpty &&
          _searchMode &&
          mounted) {
        setState(() => _searchMode = false);
      }
    });
    final title = _titleFor(state);
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        // 搜索模式：AppBar 内嵌搜索框（输入即搜）
        title: _searchMode
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索标题或备注',
                  border: InputBorder.none,
                ),
                onChanged: (v) {
                  final notifier = ref.read(tasksControllerProvider.notifier);
                  final q = v.trim();
                  if (q.isEmpty) {
                    notifier.clearSearch();
                  } else {
                    notifier.search(q);
                  }
                },
              )
            : Text(title),
        actions: [
          if (_searchMode)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '退出搜索',
              onPressed: _exitSearchMode,
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              onPressed: _enterSearchMode,
            ),
            // 已完成视图：批量恢复；其他视图：批量完成（均带撤销条）
            if (_multiSelect && state.smartView != 'done')
              IconButton(
                icon: const Icon(Icons.check),
                tooltip: '完成所选',
                onPressed: () async {
                  final ids = _selected.toList();
                  _exitMultiSelect();
                  // await 批量完成后再出撤销条（此前 fire-and-forget，
                  // 期间数据变化可能作用于过期集合）
                  // 撤销条按"实际执行集合"——被跳过的今日已完成项
                  // 不得被撤销误反转，全部跳过时不弹撤销条
                  final acted = await ref
                      .read(tasksControllerProvider.notifier)
                      .batchComplete(ids);
                  if (mounted && acted.isNotEmpty) {
                    _showUndo(
                      '已完成 ${acted.length} 个任务',
                      () => ref
                          .read(tasksControllerProvider.notifier)
                          .batchReopen(acted),
                    );
                  }
                },
              ),
          if (_multiSelect && state.smartView == 'done')
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: '恢复所选',
              onPressed: () async {
                final ids = _selected.toList();
                _exitMultiSelect();
                // await 批量恢复后再出撤销条
                await ref
                    .read(tasksControllerProvider.notifier)
                    .batchReopen(ids);
                if (mounted) {
                  _showUndo(
                    '已恢复 ${ids.length} 个任务',
                    () => ref
                        .read(tasksControllerProvider.notifier)
                        .batchComplete(ids),
                  );
                }
              },
            ),
          if (_multiSelect)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除所选',
              onPressed: () => _confirmBatchDelete(),
            ),
          // D4：全选 / 取消全选
          if (_multiSelect)
            IconButton(
              icon: Icon(
                _selected.length == state.tasks.length
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              tooltip: '全选',
              onPressed: () {
                setState(() {
                  if (_selected.length == state.tasks.length) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(state.tasks.map((t) => t.id));
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
          if (!_multiSelect)
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: '排序',
              onPressed: () => _showSortMenu(state),
            ),
          // C8-7：已完成视图提供"清空已完成"入口
          if (!_multiSelect && state.smartView == 'done' && state.tasks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空已完成',
              onPressed: () => _confirmClearCompleted(),
            ),
          ],
        ],
      ),
      drawer: _TaskDrawer(
        onMultiSelectChange: (v) => setState(() => _multiSelect = v),
      ),
      // 禁用 Scaffold 自带的边缘拖拽（默认 20px 左缘区）：任务页已有全局
      // GestureDetector 右滑开抽屉（_navDragDx），且横屏下左缘约 100px 为
      // 系统返回手势区，Scaffold 默认边缘拖拽会与系统手势竞争导致
      // "左滑想开抽屉却退出 App"（与日历页 drawerEdgeDragWidth: 0 对齐）
      drawerEdgeDragWidth: 0,
      // 空白处左右滑导航：从左向右滑打开抽屉、从右向左滑切日历（翻页式：下一个 tab）
      // 5.5 手势优先级：任务卡片上的水平滑动由 Dismissible 赢得（完成/更多操作），
      // 空白/列表间隙处由本 GestureDetector 接管（切 tab/开抽屉），区域天然隔离。
      // 加累计位移门槛（>40px）避免快速轻扫误触发。
      body: GestureDetector(
        // opaque：空状态/空白区域也能命中手势（否则空任务时滑动无效）
        behavior: HitTestBehavior.opaque,
        // 手势开始/取消时重置累计位移（此前只在结束归零，
        // 手势被取消会残留位移叠加到下一次拖动）
        onHorizontalDragStart: (_) => _navDragDx = 0,
        onHorizontalDragUpdate: (d) => _navDragDx += d.delta.dx,
        onHorizontalDragCancel: () => _navDragDx = 0,
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v > 300 && _navDragDx > 40) {
            _scaffoldKey.currentState?.openDrawer();
          } else if (v < -300 && _navDragDx < -40) {
            widget.onNavigateNext?.call();
          }
          _navDragDx = 0;
        },
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(state),
      ),
      // D3：多选时隐藏 FAB，避免遮挡底部栏（缩放+淡出过渡，禁点）
      floatingActionButton: AnimatedScale(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        scale: _multiSelect ? 0 : 1,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: _multiSelect ? 0 : 1,
          child: IgnorePointer(
            ignoring: _multiSelect,
            child: FloatingActionButton(
              onPressed: _openQuickAdd,
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
  }

  String _titleFor(TasksState state) {
    if (state.searchQuery.isNotEmpty) return '搜索';
    switch (state.smartView) {
      case 'today':
        return '今天';
      case 'week7':
        return '未来 7 天';
      case 'all':
        return '全部';
      case 'done':
        return '已完成';
      case 'list':
        final l = state.lists
            .where((l) => l.id == state.currentListId)
            .firstOrNull;
        return l?.name ?? '清单';
    }
    return '全部';
  }

  Widget _buildBody(TasksState state) {
    final searching = state.searchQuery.isNotEmpty;
    if (state.tasks.isEmpty) {
      return _EmptyView(
        searching: searching,
        query: state.searchQuery,
        onClearSearch: searching
            ? () => ref.read(tasksControllerProvider.notifier).clearSearch()
            : null,
        onAddFirst: searching ? null : _openQuickAdd,
      );
    }
    final visible = state.tasks;
    // findChildIndexCallback 用的 id → index 映射
    final indexById = {
      for (var i = 0; i < visible.length; i++) visible[i].id: i,
    };
    return Column(
      children: [
        // 头部概览：日期 + 当前视图（非搜索、非多选时展示）
        if (!searching && !_multiSelect)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _TaskHeader(title: _titleFor(state)),
          ),
        // 搜索模式：结果计数提示
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '找到 ${state.tasks.length} 个任务',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              // 只重载当前视图，不跳回"全部"
              await ref.read(tasksControllerProvider.notifier).reload();
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              // 底部留白 = 屏高一半：最后一项可滚动到屏幕中央，方便在手势
              // 区中点按；下限 120 保证右下角"添加" FAB 不遮挡最后一项
              padding: EdgeInsets.only(
                top: 4,
                bottom: math.max(
                  120.0,
                  MediaQuery.sizeOf(context).height * 0.5,
                ),
              ),
              itemCount: visible.length,
              // 任务 id → index 映射：完成/删除/插入导致条目位移时按 key
              // 找回原有 element，防止位移条目 remount 使入场动画集体重播
              findChildIndexCallback: (key) {
                final s = key is ValueKey<String> ? key.value : null;
                if (s == null) return null;
                final id = int.tryParse(
                  s.startsWith('enter-') ? s.substring(6) : s.substring(5),
                );
                if (id == null) return null;
                return indexById[id];
              },
              itemBuilder: (context, index) {
                final t = visible[index];
                final listColor = state.lists
                    .where((l) => l.id == t.listId)
                    .firstOrNull
                    ?.color;
                // 重复任务：完成状态 = 今天实例状态；非重复 = completedAt
                final done = t.rrule.isNotEmpty
                    ? (state.instanceDone[t.id] ?? false)
                    : t.completedAt != null;
                final tile = _TaskTile(
                  key: ValueKey('task-${t.id}'),
                  task: t,
                  done: done,
                  todayHas: t.rrule.isNotEmpty
                      ? (state.todayHas[t.id] ?? false)
                      : null,
                  nextInstance: t.rrule.isNotEmpty
                      ? state.nextInstance[t.id]
                      : null,
                  listColorHex: listColor,
                  multiSelect: _multiSelect,
                  selected: _selected.contains(t.id),
                  onLongPress: () {
                    if (!_multiSelect) {
                      Haptics.select();
                      setState(() {
                        _multiSelect = true;
                        _selected.add(t.id);
                      });
                    }
                  },
                  onTap: () {
                    if (_multiSelect) {
                      setState(() {
                        if (!_selected.add(t.id)) {
                          _selected.remove(t.id);
                          if (_selected.isEmpty) _multiSelect = false;
                        }
                      });
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TaskDetailPage(taskId: t.id),
                        ),
                      );
                    }
                  },
                  onSwipeComplete: () => _toggleComplete(t),
                  onSwipeMore: () => _showMoreSheet(t),
                );
                // A3：新任务首次出现时从顶部滑入 + 淡入（key 变化才重播）
                // A4：搜索逐键过滤/批量操作时禁用入场动画——结果集高频变化
                // 时逐项播动画会导致列表跳动闪烁
                if (state.searchQuery.isNotEmpty || _multiSelect) {
                  return tile;
                }
                return TweenAnimationBuilder<double>(
                  key: ValueKey('enter-${t.id}'),
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, child) => Opacity(
                    opacity: v,
                    child: Transform.translate(
                      offset: Offset(0, -14 * (1 - v)),
                      child: child,
                    ),
                  ),
                  child: tile,
                );
              },
            ),
          ),
        ),
        // 多选底栏：高度变化走 AnimatedSize，列表视口平滑让位
        //（此前瞬间插入导致列表整体跳动）
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: _multiSelect
              ? SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Text('已选 ${_selected.length} 项'),
                        const Spacer(),
                        TextButton.icon(
                          icon: const Icon(Icons.drive_file_move_outline),
                          label: const Text('移动'),
                          onPressed: _selected.isEmpty
                              ? null
                              : () => _showMoveSheet(),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _selected.clear();
    });
  }

  /// C8-7：清空已完成任务（含重复任务今日实例记录），确认后执行
  Future<void> _confirmClearCompleted() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空已完成？'),
        content: const Text('将删除全部已完成任务与重复任务的实例完成记录'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('清空', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(tasksControllerProvider.notifier).clearCompleted();
    // 清空操作不可撤销（此前撤销条回调为空操作，误导性 UI）；
    // 改为无撤销按钮的普通提示
    if (mounted) {
      showAppSnackBar(
        context,
        '已清空已完成任务',
        icon: Icons.delete_sweep_outlined,
      );
    }
  }

  Future<void> _confirmBatchDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除所选任务？'),
        content: Text('将删除 ${_selected.length} 个任务及其子任务，移入回收站可恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final ids = _selected.toList();
      _exitMultiSelect();
      await ref.read(tasksControllerProvider.notifier).batchDelete(ids);
      if (mounted) {
        _showUndo(
          '已删除 ${ids.length} 个任务',
          () => ref
              .read(tasksControllerProvider.notifier)
              .batchUndoDelete(ids),
          icon: Icons.delete_outline,
        );
      }
    }
  }

  void _showMoveSheet() {
    final lists = ref.read(tasksControllerProvider).lists;
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('移动到清单')),
            ...lists.map(
              (l) => ListTile(
                leading: Icon(
                  Icons.circle,
                  color: colorFromHex(l.color),
                  size: 16,
                ),
                title: Text(l.name),
                onTap: () async {
                  Navigator.pop(c);
                  final ids = _selected.toList();
                  _exitMultiSelect();
                  final notifier = ref.read(tasksControllerProvider.notifier);
                  // C8-3：批量移动带撤销（快照各任务原清单）
                  final originals = <int, int>{};
                  final state = ref.read(tasksControllerProvider);
                  for (final id in ids) {
                    final t = state.tasks.where((x) => x.id == id).firstOrNull;
                    if (t != null) originals[id] = t.listId;
                  }
                  await notifier.batchMove(ids, l.id);
                  if (mounted && originals.isNotEmpty) {
                    _showUndo(
                      '已移动 ${ids.length} 个任务',
                      () async {
                        for (final e in originals.entries) {
                          await notifier.updateTaskFields(
                            e.key,
                            TasksCompanion(listId: Value(e.value)),
                          );
                        }
                      },
                      icon: Icons.drive_file_move_outline,
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSortMenu(TasksState state) {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('排序方式')),
            ...[('time', '按时间'), ('quadrant', '按象限')].map(
              (e) => RadioListTile<String>(
                value: e.$1,
                groupValue: state.sortMode,
                title: Text(e.$2),
                onChanged: (v) {
                  ref.read(tasksControllerProvider.notifier).setSortMode(v!);
                  Navigator.pop(c);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMoreSheet(Task t) {
    final done = _isDone(t);
    // 今天是否命中规则（非规则日无"今天实例"可完成）
    final todayHas = t.rrule.isNotEmpty
        ? (ref.read(tasksControllerProvider).todayHas[t.id] ?? false)
        : null;
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
            ),
            ListTile(
              leading: const Icon(Icons.event),
              title: Text(t.rrule.isNotEmpty ? '修改重复时间' : '改期'),
              onTap: () async {
                Navigator.pop(c);
                await _pickDate(t);
              },
            ),
            // 今天非规则日 → 无"今天实例"，隐藏完成本次（防止写入
            // 不存在的实例记录；跳过/改期本次仍可用）
            if (t.rrule.isNotEmpty && (todayHas ?? true)) ...[
              ListTile(
                leading: Icon(
                  done ? Icons.undo : Icons.check_circle_outline,
                ),
                title: Text(done ? '撤销完成本次' : '完成本次'),
                onTap: () {
                  Navigator.pop(c);
                  final instDay = TasksController.currentInstanceDate(t);
                  final notifier = ref.read(tasksControllerProvider.notifier);
                  notifier.completeTask(t.id);
                  if (mounted) {
                    // completeTask 是切换语义（完成↔撤销），撤销回调
                    // 统一再切一次即可恢复原状态（此前用 reopenTask 无条件
                    // 撤销，done=true 时撤销条反而取消用户的操作）
                    _showUndo(
                      done
                          ? '已撤销 ${DateUtilsEx.dateCn(instDay)} 的完成'
                          : '已完成 ${DateUtilsEx.dateCn(instDay)} 的实例',
                      () => notifier.completeTask(t.id),
                    );
                  }
                },
              ),
            ],
            if (t.rrule.isNotEmpty) ...[
              ListTile(
                leading: const Icon(Icons.event_repeat),
                title: const Text('改期本次'),
                onTap: () {
                  Navigator.pop(c);
                  _rescheduleInstance(t);
                },
              ),
              ListTile(
                leading: const Icon(Icons.skip_next),
                title: const Text('跳过本次'),
                onTap: () {
                  Navigator.pop(c);
                  final instDay = TasksController.currentInstanceDate(t);
                  final notifier = ref.read(tasksControllerProvider.notifier);
                  notifier.skipInstance(t.id, instDay);
                  _showUndo(
                    '已跳过 ${DateUtilsEx.dateCn(instDay)} 的实例',
                    () => notifier.unskipInstance(t.id, instDay),
                    icon: Icons.skip_next,
                  );
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移到清单'),
              onTap: () {
                Navigator.pop(c);
                _moveSingle(t);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(c);
                // 5.6：立即删除（撤销条即时出现，不再等退出动画）
                _deleteTask(t);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 改期（日期 + 时间两步，保持时长；带撤销）
  Future<void> _pickDate(Task t) async {
    final now = AppClock.now();
    final initial = t.planStart ?? now;
    // initialDate 钳制到 [firstDate, lastDate]（长期任务的 planStart
    // 可早于一年前，超界触发 debug 断言崩溃 / release 月份错乱）
    final first = DateTime(now.year - 1);
    final last = DateTime(now.year + 5);
    final clamped = initial.isBefore(first)
        ? first
        : (initial.isAfter(last) ? last : initial);
    final picked = await showDatePicker(
      context: context,
      initialDate: clamped,
      firstDate: first,
      lastDate: last,
      helpText: '选择改期日期',
    );
    if (picked == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      helpText: '选择改期时间',
    );
    if (pickedTime == null || !mounted) return;
    final notifier = ref.read(tasksControllerProvider.notifier);
    final ps = t.planStart;
    final pe = t.planEnd;
    final newStart = AppClock.at(
      picked.year,
      picked.month,
      picked.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    // C5-3：全天任务改期（选具体时间）时长按 1 小时——
    // 此前沿用 24 小时时长（pe-ps=次日），改期后变跨天任务
    final durationMinutes = t.isAllDay
        ? 60
        : (pe == null || ps == null ? 60 : pe.difference(ps).inMinutes);
    // （A13-2 第四处遗漏）：重复任务"修改重复时间"= 平移系列锚点，
    // 开始日期自动吸附到距其最近的规则命中日——否则锚点不命中规则
    // （如每周一任务改到周二）时系列从日历/列表消失
    var effectiveStart = newStart;
    if (t.rrule.isNotEmpty) {
      final hit = RruleService.instance.nearestHitOnOrNear(
        AppClock.at(newStart.year, newStart.month, newStart.day),
        t.rrule,
      );
      if (hit != null) {
        effectiveStart = AppClock.at(
          hit.year,
          hit.month,
          hit.day,
          newStart.hour,
          newStart.minute,
        );
      }
    }
    final newEnd = effectiveStart.add(Duration(minutes: durationMinutes));
    // 重复任务改期（平移系列锚点）统一收口——清理不再匹配新锚点的
    // 旧完成记录/例外（此前直接 updateTaskFields，旧记录成孤儿参与统计）
    var removedCount = 0;
    RecurringChangeResult? changeResult;
    if (t.rrule.isNotEmpty &&
        !DateUtilsEx.sameDay(t.planStart ?? effectiveStart, effectiveStart)) {
      final db = ref.read(dbProvider);
      changeResult = await db.applyRecurringChange(
        t.id,
        oldRrule: t.rrule,
        newRrule: t.rrule,
        newStart: effectiveStart,
      );
      removedCount = changeResult.removedCompletions.length;
    }
    // 所有改期路径都存撤销快照（此前仅在重复任务锚点吸附时存，
    // 非重复任务改期后撤销条点击无任何效果）：
    // - 非重复任务：恢复原 planStart/planEnd
    // - 重复任务：恢复原锚点 + 被清理的完成记录/例外
    _lastRescheduleUndo = _RescheduleUndo(
      t,
      ps,
      pe,
      changeResult ?? const RecurringChangeResult(),
    );
    await notifier.updateTaskFields(
      t.id,
      TasksCompanion(
        planStart: Value<DateTime?>(effectiveStart),
        planEnd: Value<DateTime?>(newEnd),
      ),
    );
    // 改期成功 → 播放移动/落下提示音（与日历拖拽/详情页改期同一 drop 音）
    SoundService.instance.play(SoundKind.drop);
    if (mounted) {
      // 吸附发生且有清理时合并提示（避免两条 Snackbar 互相覆盖）
      final adjusted = !DateUtilsEx.sameDay(newStart, effectiveStart);
      final msg = adjusted
          ? '开始日期与重复规则不匹配，已自动调整到 '
              '${DateUtilsEx.dateCn(effectiveStart)}'
              '${removedCount > 0 ? '，已清理 $removedCount 条不再匹配的完成记录' : ''}'
          : (removedCount > 0
              ? '已清理 $removedCount 条不再匹配新日期的完成记录'
              : '已改期到 ${DateUtilsEx.dateCn(effectiveStart)} '
                  '${DateUtilsEx.timeCn(effectiveStart)}');
      _showUndo(
        msg,
        // 撤销恢复原锚点 + 被清理的完成记录/例外（与日历系列改期
        // 撤销 undoMoveTaskSeries 一致；此前只恢复日期，历史数据永久缺失）
        () async {
          await _undoReschedule();
        },
        icon: Icons.event,
      );
    }
  }

  /// 任务页改期撤销快照（恢复被清理的完成记录与例外）
  _RescheduleUndo? _lastRescheduleUndo;

  Future<void> _undoReschedule() async {
    final u = _lastRescheduleUndo;
    _lastRescheduleUndo = null;
    if (u == null) return;
    final db = ref.read(dbProvider);
    final notifier = ref.read(tasksControllerProvider.notifier);
    // 撤销改期成功 → 播放恢复音（此前撤销无声）
    SoundService.instance.play(SoundKind.reopen);
    await notifier.updateTaskFields(
      u.task.id,
      TasksCompanion(
        planStart: Value<DateTime?>(u.oldStart),
        planEnd: Value<DateTime?>(u.oldEnd),
      ),
    );
    for (final c in u.result.removedCompletions) {
      await db.insertCompletionRaw(
        TaskCompletionsCompanion(
          id: Value(c.id),
          taskId: Value(c.taskId),
          instanceDate: Value(c.instanceDate),
          completedAt: Value(c.completedAt),
        ),
      );
    }
    for (final e in u.result.removedExceptions) {
      await db.insertExceptionRaw(
        TaskExceptionsCompanion(
          id: Value(e.id),
          taskId: Value(e.taskId),
          instanceDate: Value(e.instanceDate),
          action: Value(e.action),
          overrideScheduledDate: e.overrideScheduledDate == null
              ? const Value(null)
              : Value(e.overrideScheduledDate),
        ),
      );
    }
  }

  /// 重复任务：改期本次实例（日期 + 时间，写例外）
  Future<void> _rescheduleInstance(Task t) async {
    final instDay = TasksController.currentInstanceDate(t);
    final now = AppClock.now();
    // 默认时间 = 原计划时分
    final ps = t.planStart;
    final picked = await showDatePicker(
      context: context,
      initialDate: instDay,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: '改期本次到',
    );
    if (picked == null || !mounted) return;
    // ps 为 DB 读回值（系统时区字段），先按应用时区解释再取时分
    final pa = ps == null ? null : AppClock.asApp(ps);
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: pa?.hour ?? 9,
        minute: pa?.minute ?? 0,
      ),
      helpText: '选择实例时间',
    );
    if (pickedTime == null || !mounted) return;
    // 与详情页/日历弹层同口径：按应用时区构造（普通 DateTime 会按系统时区解释）
    final toDate = AppClock.at(
      picked.year,
      picked.month,
      picked.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    final notifier = ref.read(tasksControllerProvider.notifier);
    // 记录例外 ID，撤销时删除该例外（而非新增反向例外）
    final exId = await notifier.editException(t.id, instDay, toDate);
    // 改期本次成功 → 播放移动/落下提示音（与日历拖拽改期同一 drop 音）
    SoundService.instance.play(SoundKind.drop);
    if (mounted) {
      _showUndo(
        '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
        // 撤销：删除改期例外，恢复到原日期（成功后播恢复音）
        () async {
          await notifier.undoEditException(t.id, exId);
          SoundService.instance.play(SoundKind.reopen);
        },
        icon: Icons.event_repeat,
      );
    }
  }

  void _moveSingle(Task t) {
    final lists = ref.read(tasksControllerProvider).lists;
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: lists
              .map(
                (l) => ListTile(
                  leading: Icon(
                    Icons.circle,
                    color: colorFromHex(l.color),
                    size: 16,
                  ),
                  title: Text(l.name),
                  onTap: () {
                    Navigator.pop(c);
                    ref
                        .read(tasksControllerProvider.notifier)
                        .updateTaskFields(
                          t.id,
                          TasksCompanion(listId: Value(l.id)),
                        );
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  /// D2：美化的撤销条（浮动圆角卡片，3 秒消失；新条替换旧条不堆积）
  void _showUndo(
    String text,
    VoidCallback onUndo, {
    IconData icon = Icons.check,
  }) {
    showAppSnackBar(
      context,
      text,
      actionLabel: '撤销',
      onAction: onUndo,
      icon: icon,
      aboveFab: true,
    );
  }

  void _openQuickAdd() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 与日历快建一致：250ms 默认动画 + 键盘弹出叠加体感慢，缩短到 120ms
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 120),
        reverseDuration: Duration(milliseconds: 120),
      ),
      builder: (c) => const QuickAddSheet(),
    );
  }
}

/// 任务页改期撤销快照（原锚点 + 被清理的完成记录/例外）
class _RescheduleUndo {
  final Task task;
  final DateTime? oldStart;
  final DateTime? oldEnd;
  final RecurringChangeResult result;

  _RescheduleUndo(this.task, this.oldStart, this.oldEnd, this.result);
}

/// 快速添加弹窗
class QuickAddSheet extends ConsumerStatefulWidget {
  const QuickAddSheet({super.key});

  @override
  ConsumerState<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<QuickAddSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: padding),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ParseHintTextField(
                controller: _controller,
                hintText: '输入任务，如：明天下午3点交报告',
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: _submitAndOpenDetail,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('添加并编辑'),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _submit, child: const Text('添加')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final text = _controller.text.trim();
    // C4-4：空文本统一提示（此前静默无反应；"添加并编辑"仍创建"未命名"）
    if (text.isEmpty) {
      showAppSnackBar(
        context,
        '请输入任务内容',
        icon: Icons.info_outline,
      );
      return;
    }
    final parsed = ChineseDateParser.instance.parse(text);
    final title = _extractTitle(text);
    ref.read(tasksControllerProvider.notifier).addTaskFromParsed(title, parsed);
    _controller.clear();
    Navigator.pop(context);
  }

  /// 快速创建后展开详情页继续编辑（C4：空标题也创建"未命名"进入详情）
  Future<void> _submitAndOpenDetail() async {
    final text = _controller.text.trim();
    final parsed = ChineseDateParser.instance.parse(text);
    final title = text.isEmpty ? '未命名' : _extractTitle(text);
    final id = await ref
        .read(tasksControllerProvider.notifier)
        .addTaskFromParsed(title, parsed);
    _controller.clear();
    if (!mounted) return;
    Navigator.pop(context);
    if (id != null) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: id)));
    }
  }

  /// 从输入中提取标题（去掉已识别的时间词）
  /// 从输入中提取标题（去掉已识别的时间词）
  /// 统一走公共实现 extractTaskTitle（日历快速添加共用，
  /// 此前两份重复实现且逐词删除会撕裂标题）
  String _extractTitle(String input) => extractTaskTitle(input);
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    super.key,
    required this.task,
    required this.done,
    required this.multiSelect,
    required this.selected,
    required this.onLongPress,
    required this.onTap,
    required this.onSwipeComplete,
    required this.onSwipeMore,
    this.todayHas,
    this.nextInstance,
    this.listColorHex,
  });

  final Task task;
  /// 完成状态（重复任务 = 今天实例完成；非重复 = completedAt）
  final bool done;
  final bool multiSelect;
  final bool selected;
  /// 重复任务：今天是否命中规则（null = 非重复任务）
  final bool? todayHas;
  /// 重复任务：下一个未完成实例（null = 非重复任务）
  final DateTime? nextInstance;
  final String? listColorHex;
  final VoidCallback onLongPress;
  final VoidCallback onTap;
  final VoidCallback onSwipeComplete;
  final VoidCallback onSwipeMore;

  @override
  Widget build(BuildContext context) {
    final overdue = task.isOverdueNow;
    final color = overdue ? Theme.of(context).colorScheme.error : null;
    final listColor = listColorHex == null ? null : colorFromHex(listColorHex!);
    // 非重复任务完成后会从当前视图移除 → 右滑放行给 onDismissed，
    // 走原生滑出+收起动画（此前 confirmDismiss 固定 false 导致
    // "滑出→跳回→稍后硬消失"的割裂感）；
    // 重复任务完成后仍留在原地（划线）→ 保持回弹，配合控制器的
    // 乐观更新让勾选/划线即时翻转
    final dismissToComplete = task.rrule.isEmpty;
    return Dismissible(      key: ValueKey('task-${task.id}'),
      // 多选模式下禁用横滑手势（防误完成/误开更多操作）
      direction: multiSelect
          ? DismissDirection.none
          : DismissDirection.horizontal,
      // C8-6：滑动时显示方向语义背景（右滑=完成、左滑=更多），
      // B4：用主题容器色替代硬编码绿/橙（暗色下协调，且不与任务色语义冲突）
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: AppRadius.tile,
        ),
        child: Icon(
          Icons.check_circle_outline,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.tertiaryContainer.withValues(alpha: 0.45),
          borderRadius: AppRadius.tile,
        ),
        child: Icon(
          Icons.more_horiz,
          color: Theme.of(context).colorScheme.tertiary,
        ),
      ),
      // A5：恢复回弹动画（此前 movementDuration: 0 导致松手瞬间硬跳回；
      // 与之冲突的自定义淡出动画已在 5.6 移除，可安全启用回弹）
      movementDuration: const Duration(milliseconds: 180),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          if (dismissToComplete) return true;
          onSwipeComplete();
          return false;
        }
        onSwipeMore();
        return false;
      },
      // 仅非重复任务会走到这里（confirmDismiss 放行后滑出+收起完成时回调），
      // 此刻卡片已离场，写库/撤销条在后台进行，reload 落地后条目自然移除
      onDismissed: dismissToComplete ? (_) => onSwipeComplete() : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: AppRadius.tile,
        child: Container(
          // 拟物卡片：圆角 + 背景 + 细边框 + 轻微阴影
          // 卡片用 surfaceContainerLow 抬升一档，与列表底面 surface 形成层次
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: AppRadius.tile,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.only(left: 14, right: 8, top: 8, bottom: 8),
          child: Row(
            children: [
              if (listColor != null)
                Container(
                  width: 5,
                  height: 30,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: listColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              if (multiSelect)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeOut,
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: Checkbox(
                    key: const ValueKey('checkbox'),
                    value: selected,
                    onChanged: (_) => onTap(),
                  ),
                )
              else
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeOut,
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: IconButton(
                    key: const ValueKey('icon'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: DoneCheckIcon(done: done),
                    onPressed: onSwipeComplete,
                  ),
                ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: TextStyle(
                        decoration: done ? TextDecoration.lineThrough : null,
                        color: done
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : color,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_subtitle(context) != null)
                      Text(
                        _subtitle(context)!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (task.quadrant < 4)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: quadrantColors[task.quadrant.clamp(0, 3)],
                    shape: BoxShape.circle,
                  ),
                ),
              if (task.hasReminder)
                Icon(
                  Icons.notifications_none,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: 6),
              if (task.hasNote)
                Icon(Icons.notes, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  String? _subtitle(BuildContext context) {
    final parts = <String>[];
    if (task.quadrant < 4) {
      parts.add(quadrantNames[task.quadrant]);
    }
    final ps = task.planStart;
    // 重复任务：显示当前实例状态（今天完成/下次实例日期）
    if (task.rrule.isNotEmpty) {
      final todayHit = todayHas ?? true;
      final next = nextInstance;
      String dayText;
      if (todayHit) {
        dayText = done ? '✓ 今天' : '今天';
      } else if (next != null) {
        dayText = done ? '✓ 下次 ${DateUtilsEx.dateCn(next)}' : '下次 ${DateUtilsEx.dateCn(next)}';
      } else {
        dayText = done ? '✓ 今天' : '今天';
      }
      if (task.isAllDay) {
        parts.add(dayText);
      } else {
        // 时间优先取 next（含例外改期目标日/时刻）——改期本次后任务页
        // 能看到改到的新时刻，而非始终显示 planStart 的旧时分
        final base = next ?? ps ?? AppClock.now();
        final dur = (ps != null && task.planEnd != null)
            ? task.planEnd!.difference(ps)
            : const Duration(hours: 1);
        final end = base.add(dur);
        // 跨天实例：结束日带日期（"今天 22:00 到 明天 06:00"），
        // 避免只显示"06:00"产生跨天歧义；开始日期由 dayText 前缀承载
        parts.add(
          DateUtilsEx.sameDay(base, end)
              ? '$dayText ${DateUtilsEx.timeCn(base)}-${DateUtilsEx.timeCn(end)}'
              : '$dayText ${DateUtilsEx.timeCn(base)} 到 '
                    '${DateUtilsEx.dateCn(end)} ${DateUtilsEx.timeCn(end)}',
        );
      }
    } else if (ps != null) {
      parts.add(
        DateUtilsEx.planRangeText(ps, task.planEnd, isAllDay: task.isAllDay),
      );
    }
    if (done && task.rrule.isEmpty) {
      parts.add('✓ ${DateUtilsEx.dateCn(task.completedAt!)}');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

class _TaskDrawer extends ConsumerWidget {
  const _TaskDrawer({required this.onMultiSelectChange});

  final ValueChanged<bool> onMultiSelectChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(tasksControllerProvider);
    final notifier = ref.read(tasksControllerProvider.notifier);
    // 抽屉切换视图/清单时退出多选（否则 _selected 残留旧视图任务，
    // 批量操作会作用于不可见任务）
    void selectAndClose(VoidCallback select) {
      onMultiSelectChange(false);
      select();
      Navigator.pop(context);
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // 横屏/小屏：抽屉内容超出视口溢出（BOTTOM OVERFLOWED 100px），
            // 智能视图 + 清单区改为可滚动（Flexible + SingleChildScrollView），
            // 新建清单固定在底部
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.home),
                      title: Text(
                        '全部',
                        style: TextStyle(
                          fontWeight: state.smartView == 'all'
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                      selected: state.smartView == 'all',
                      onTap: () =>
                          selectAndClose(() => notifier.selectSmartView('all')),
                    ),
                    ListTile(
                      leading: const Icon(Icons.today),
                      title: Text(
                        '今天',
                        style: TextStyle(
                          fontWeight: state.smartView == 'today'
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                      selected: state.smartView == 'today',
                      onTap: () => selectAndClose(
                        () => notifier.selectSmartView('today'),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.date_range),
                      title: Text(
                        '未来 7 天',
                        style: TextStyle(
                          fontWeight: state.smartView == 'week7'
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                      selected: state.smartView == 'week7',
                      onTap: () => selectAndClose(
                        () => notifier.selectSmartView('week7'),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text(
                        '已完成',
                        style: TextStyle(
                          fontWeight: state.smartView == 'done'
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                      selected: state.smartView == 'done',
                      onTap: () => selectAndClose(
                        () => notifier.selectSmartView('done'),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('回收站'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const TrashPage(),
                          ),
                        );
                      },
                    ),
                    // 搜索入口在右上角（AppBar 图标），侧边栏不再重复
                    const Divider(),
                    // 收件箱（默认清单）与其他清单一起显示，sortOrder=0 排最前
                    for (final l in state.lists)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.circle,
                          color: colorFromHex(l.color),
                          size: 18,
                        ),
                        title: Text(
                          l.name,
                          style: TextStyle(
                            fontWeight: state.currentListId == l.id
                                ? FontWeight.bold
                                : null,
                          ),
                        ),
                        selected: state.currentListId == l.id,
                        onTap: () =>
                            selectAndClose(() => notifier.selectList(l.id)),
                        onLongPress: () =>
                            _showListActions(context, ref, l, notifier),
                      ),
                  ],
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('新建清单'),
              onTap: () => _showCreateListDialog(context, ref, notifier),
            ),
          ],
        ),
      ),
    );
  }

  void _showListActions(
    BuildContext context,
    WidgetRef ref,
    TaskList l,
    TasksController notifier,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(l.name), dense: true),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(c);
                _showRenameDialog(context, l, notifier);
              },
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('更改颜色'),
              onTap: () {
                Navigator.pop(c);
                _showColorDialog(context, l, notifier);
              },
            ),
            ListTile(
              leading: Icon(
                l.showInCalendar ? Icons.visibility : Icons.visibility_off,
              ),
              title: Text(l.showInCalendar ? '日历中隐藏' : '日历中显示'),
              onTap: () {
                Navigator.pop(c);
                notifier.toggleListCalendar(l.id, !l.showInCalendar);
              },
            ),
            // 默认清单（收件箱）不可删除：删除后系统无默认清单会崩溃
            if (!l.isDefault)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                title: Text('删除清单', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () {
                  Navigator.pop(c);
                  _confirmDeleteList(context, ref, l, notifier);
                },
              )
            else
              ListTile(
                leading: Icon(
                  Icons.lock_outline,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  '默认清单不可删除',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                ),
                dense: true,
                onTap: () {
                  Navigator.pop(c);
                  showAppSnackBar(
                    context,
                    '「${l.name}」是默认清单，不可删除',
                    icon: Icons.lock_outline,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateListDialog(
    BuildContext context,
    WidgetRef ref,
    TasksController notifier,
  ) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建清单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '清单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await notifier.createList(name, '#4F8EF7');
    }
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    TaskList l,
    TasksController notifier,
  ) async {
    final controller = TextEditingController(text: l.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名清单'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await notifier.renameList(l.id, name);
    }
  }

  void _showColorDialog(
    BuildContext context,
    TaskList l,
    TasksController notifier,
  ) {
    const colors = [
      '#4F8EF7',
      '#E53935',
      '#43A047',
      '#FB8C00',
      '#8E24AA',
      '#00ACC1',
      '#FDD835',
      '#6D4C41',
      '#546E7A',
      '#C0CA33',
    ];
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('选择颜色'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          // 修复：spacing 12 偏挤且缺 runSpacing（换行后行间距为 0，
          // 上下颜色框贴死）；增大间距 + 补 runSpacing + 选中边框
          child: Wrap(
            spacing: 18,
            runSpacing: 18,
            children: colors
                .map(
                  (hex) => InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      notifier.changeListColor(l.id, hex);
                      Navigator.pop(c);
                    },
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: l.color == hex
                              ? Theme.of(c).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircleAvatar(
                          backgroundColor: colorFromHex(hex),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteList(
    BuildContext context,
    WidgetRef ref,
    TaskList l,
    TasksController notifier,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除清单「${l.name}」'),
        content: const Text('清单内的任务怎么处理？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'move'),
            child: const Text('转移到收件箱'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'delete'),
            child: Text('连带删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (choice == 'move') {
      await notifier.deleteList(l.id, deleteTasks: false);
    } else if (choice == 'delete') {
      // C8-4：连带删除走撤销快照（此前直接删、无撤销；
      // 逐个删除反而可撤销，行为不一致）
      final db = ref.read(dbProvider);
      final tasks = await db.getTasksByList(l.id);
      final topLevel = tasks.where((t) => t.parentId == null).toList();
      for (final t in topLevel) {
        await notifier.deleteTaskWithUndo(t.id);
      }
      await notifier.deleteList(l.id, deleteTasks: false);
      if (context.mounted && topLevel.isNotEmpty) {
        showAppSnackBar(
          context,
          '已删除清单「${l.name}」及其 ${topLevel.length} 个任务',
          actionLabel: '撤销',
          onAction: () async {
            // 撤销连带删除必须先恢复清单，否则任务恢复时
            // listId 外键引用缺失导致崩溃、数据永久丢失
            await db.restoreList(l);
            for (final t in topLevel) {
              await notifier.undoDelete(t.id);
            }
          },
          icon: Icons.delete_outline,
        );
      }
    }
  }
}

/// 任务页头部概览：大日期 + 当前视图名（纯展示，零 DB 查询）
class _TaskHeader extends StatelessWidget {
  const _TaskHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = AppClock.now();
    final dateStr = '${now.month}月${now.day}日';
    final weekStr = DateUtilsEx.weekdayCn[now.weekday - 1];
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dateStr,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                weekStr,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // 「今天」徽章：未来/今天视图下才显示（表示当前视图范围起点）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.45),
            borderRadius: AppRadius.pill,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_today, size: 13, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({
    required this.searching,
    this.query = '',
    this.onClearSearch,
    this.onAddFirst,
  });

  final bool searching;
  /// 搜索关键词（空态文案展示）
  final String query;
  /// 清除搜索按钮回调（非搜索空态为 null 不显示）
  final VoidCallback? onClearSearch;
  /// 空状态"添加第一个任务"按钮（非搜索空态）
  final VoidCallback? onAddFirst;

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: searching ? Icons.search_off : Icons.task_alt,
      title: searching
          ? (query.isEmpty ? '没有找到相关任务' : '没有找到与「$query」相关的任务')
          : '还没有任务',
      subtitle: searching ? null : '让事事有着落，从一个小任务开始',
      action: !searching && onAddFirst != null
          ? FilledButton.icon(
              onPressed: onAddFirst,
              icon: const Icon(Icons.add),
              label: const Text('添加第一个任务'),
            )
          : null,
      actions: [if (onClearSearch != null) ...[
        TextButton.icon(
          onPressed: onClearSearch,
          icon: const Icon(Icons.close, size: 16),
          label: const Text('清除搜索'),
        ),
      ]],
    );
  }
}
