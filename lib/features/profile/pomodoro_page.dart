import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/theme/theme.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('番茄专注')),
      // 拆分为独立小块按需 watch：每秒 tick 只重建倒计时文本本身，
      // 不再整页（含按钮/关联卡）每秒重建（此前 watch 整个状态对象）
      // LayoutBuilder + SingleChildScrollView：横屏/小屏内容（72 号倒计时
      // + chips + 按钮组 + 关联卡 ≈330dp）超出视口时改为可滚动，
      // 不再溢出；正常屏幕 minHeight=视口，Column 居中视觉不变
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _DurationLabel(),
                SizedBox(height: 16),
                _CountdownText(),
                SizedBox(height: 24),
                _DurationChips(),
                SizedBox(height: 24),
                _ControlButtons(),
                SizedBox(height: 24),
                _LinkedTaskCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话时长标签（"25 分钟"）——仅 minutes 变化时重建
class _DurationLabel extends ConsumerWidget {
  const _DurationLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minutes = ref.watch(
      pomodoroControllerProvider.select((s) => s.minutes),
    );
    return Text(
      '$minutes 分钟',
      style: TextStyle(fontSize: AppTextSizes.title, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// 倒计时文本——唯一每秒重建的块
class _CountdownText extends ConsumerWidget {
  const _CountdownText();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pomodoroControllerProvider);
    final mm = (status.remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (status.remainingSeconds % 60).toString().padLeft(2, '0');
    return Text(
      '$mm:$ss',
      style: TextStyle(
        fontSize: 72,
        fontWeight: FontWeight.bold,
        // 亮色黑字 / 暗色白字，随主题联动（此前未显式指定颜色）
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// 时长选择 chips——仅 minutes / 是否空闲变化时重建
class _DurationChips extends ConsumerWidget {
  const _DurationChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minutes = ref.watch(
      pomodoroControllerProvider.select((s) => s.minutes),
    );
    final canEdit = ref.watch(
      pomodoroControllerProvider.select(
        (s) => s.state == PomodoroState.idle,
      ),
    );
    final controller = ref.read(pomodoroControllerProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final m in [15, 25, 45])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text('$m 分'),
              selected: minutes == m,
              onSelected: canEdit ? (v) => controller.setMinutes(m) : null,
            ),
          ),
      ],
    );
  }
}

/// 关联任务标题（按下时刻读取，避免按钮因任务列表变化重建）
String? _linkedTaskTitle(WidgetRef ref) {
  final taskId = ref.read(pomodoroControllerProvider).taskId;
  if (taskId == null) return null;
  final tasks = ref.read(tasksControllerProvider).tasks;
  return tasks.where((t) => t.id == taskId).firstOrNull?.title;
}

/// 操作按钮组——仅计时状态变化时重建；状态切换时尺寸+淡入过渡
/// （此前 1↔2↔3 个按钮瞬间跳变）
class _ControlButtons extends ConsumerWidget {
  const _ControlButtons();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      pomodoroControllerProvider.select((s) => s.state),
    );
    final controller = ref.read(pomodoroControllerProvider.notifier);
    final row = switch (state) {
      PomodoroState.idle => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            key: ValueKey(state),
            icon: const Icon(Icons.play_arrow),
            label: const Text('开始'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 40,
                vertical: 16,
              ),
            ),
            onPressed: () =>
                controller.start(taskTitle: _linkedTaskTitle(ref)),
          ),
        ],
      ),
      PomodoroState.running => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
      ),
      PomodoroState.paused => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
            onPressed: () =>
                controller.restart(taskTitle: _linkedTaskTitle(ref)),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.check),
            label: const Text('结束'),
            onPressed: controller.finish,
          ),
        ],
      ),
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.center,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeOut,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        ),
        child: KeyedSubtree(key: ValueKey(state), child: row),
      ),
    );
  }
}

/// 关联任务卡片——仅 taskId / 任务列表变化时重建
class _LinkedTaskCard extends ConsumerWidget {
  const _LinkedTaskCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      pomodoroControllerProvider.select((s) => s.taskId),
    );
    final tasks = ref.watch(
      tasksControllerProvider.select((s) => s.tasks),
    );
    final linked = status == null
        ? null
        : tasks.where((t) => t.id == status).firstOrNull;
    final canEdit = ref.watch(
      pomodoroControllerProvider.select(
        (s) => s.state == PomodoroState.idle,
      ),
    );
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Material(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.tile,
        child: InkWell(
          borderRadius: AppRadius.tile,
          onTap: canEdit ? () => _pickTask(ref, context) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.link, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    linked?.title ?? '关联任务（可选）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: linked == null ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _pickTask(WidgetRef ref, BuildContext context) async {
  // 关联任务改为全量未完成任务（此前 take(30) 且依赖当前视图——
  // "今天"视图下无法关联未来的计划任务）
  final controller = ref.read(pomodoroControllerProvider.notifier);
  final currentTaskId = ref.read(pomodoroControllerProvider).taskId;
  final db = ref.read(dbProvider);
  final tasks = await db.getAllUncompleted();
  if (!context.mounted) return;
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
                  : Theme.of(c).colorScheme.outline,
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
                          : Theme.of(c).colorScheme.outline,
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
