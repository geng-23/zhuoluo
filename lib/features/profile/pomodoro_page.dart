import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/features/profile/pomodoro_controller.dart';
import 'package:zhuoluo/features/task/providers.dart';

/// 番茄专注页（薄壳：计时状态由进程级 [pomodoroControllerProvider] 持有，
/// 返回页面/切后台计时不中断；计时期间通知栏常驻倒计时与控制按钮）
class PomodoroPage extends ConsumerStatefulWidget {
  const PomodoroPage({super.key});

  @override
  ConsumerState<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends ConsumerState<PomodoroPage> {
  /// 专注结束提示订阅：仅本页订阅弹 SnackBar（页面销毁后计时照常，
  /// 反馈由通知栏完成通知承担）
  StreamSubscription<PomodoroFinishResult>? _finishSub;

  @override
  void initState() {
    super.initState();
    _finishSub = ref
        .read(pomodoroControllerProvider.notifier)
        .finished
        .listen(_onFinished);
  }

  @override
  void dispose() {
    // 只取消提示订阅；计时器由控制器持有，返回页面不中断
    _finishSub?.cancel();
    super.dispose();
  }

  void _onFinished(PomodoroFinishResult result) {
    if (!mounted) return;
    if (result.error != null) {
      showAppSnackBar(
        context,
        '专注记录保存失败：${result.error}',
        icon: Icons.error_outline,
      );
      return;
    }
    showAppSnackBar(
      context,
      result.minutes == 0 ? '专注已结束' : '专注完成（${result.minutes} 分钟）',
      icon: Icons.timer_outlined,
    );
  }

  Future<void> _pickTask() async {
    // 关联任务改为全量未完成任务（此前 take(30) 且依赖当前视图——
    // "今天"视图下无法关联未来的计划任务）
    final controller = ref.read(pomodoroControllerProvider.notifier);
    // 当前状态（直接读 provider 取快照，避免触碰 StateNotifier 保护成员）
    final currentTaskId = ref.read(pomodoroControllerProvider).taskId;
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
                currentTaskId == null
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: currentTaskId == null
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
                        currentTaskId == t.id
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: currentTaskId == t.id
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
      controller.setTaskId(selected == -1 ? null : selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    // watch 整个状态：每次 tick 的 notifyListeners 都会触发重建
    final status = ref.watch(pomodoroControllerProvider);
    final mm = (status.remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (status.remainingSeconds % 60).toString().padLeft(2, '0');
    final tasks = ref.watch(tasksControllerProvider).tasks;
    final linked = status.taskId == null
        ? null
        : tasks.where((t) => t.id == status.taskId).firstOrNull;
    final canEdit = status.state == PomodoroState.idle;
    final controller = ref.read(pomodoroControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('番茄专注')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${status.minutes} 分钟',
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
                    selected: status.minutes == m,
                    onSelected: canEdit
                        ? (v) => controller.setMinutes(m)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          // 按状态显示操作按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: switch (status.state) {
              PomodoroState.idle => [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 40,
                      vertical: 16,
                    ),
                  ),
                  onPressed: () => controller.start(taskTitle: linked?.title),
                ),
              ],
              PomodoroState.running => [
                FilledButton.icon(
                  icon: const Icon(Icons.pause),
                  label: const Text('暂停'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 16,
                    ),
                  ),
                  onPressed: controller.pause,
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
                  onPressed: controller.finish,
                ),
              ],
              PomodoroState.paused => [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('继续'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 16,
                    ),
                  ),
                  onPressed: controller.resume,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.replay),
                  label: const Text('重新开始'),
                  onPressed: () => controller.restart(taskTitle: linked?.title),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('结束'),
                  onPressed: controller.finish,
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
