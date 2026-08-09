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
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';

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
  /// 数据版本订阅句柄（dispose 时 close，防泄漏）
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
    // 未分类任务（quadrant 默认 4）不再静默塞进"一般"象限，
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
