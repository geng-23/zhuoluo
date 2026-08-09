import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/features/task/providers.dart';

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
    // 立即结束（elapsedSec <= 0）记录 0 分钟
    // （此前会把完整 15/25/45 分钟记进统计）
    final elapsedMin = elapsedSec <= 0
        ? 0
        : (elapsedSec / 60).ceil().clamp(1, _minutes);
    setState(() {
      _state = _PomodoroState.idle;
      // 恢复显示待开始时长（而非 00:00）
      _remaining = _minutes * 60;
    });
    // 数据库保存成功后再显示成功反馈
    // 捕获外键异常（关联任务被删除时 insertPomodoro 抛错，此前无反馈）
    try {
      await ref.read(dbProvider).insertPomodoro(
        _taskId,
        elapsedMin,
        AppClock.now().subtract(Duration(minutes: elapsedMin)),
      );
      // 番茄记录写库后通知统计等依赖方
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
    // 关联任务改为全量未完成任务（此前 take(30) 且依赖当前视图——
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
