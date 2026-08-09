import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';

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
                    // 删除习惯前确认（此前直接删除，误触即丢打卡记录）
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
                    // 习惯数据变更通知
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
    var time = AppClock.at(
      AppClock.now().year,
      AppClock.now().month,
      AppClock.now().day,
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
      // 习惯数据变更通知
      bumpDataVersion(ref);
      if (draft.reminderTime != null) {
        final habit = await db.getHabit(id);
        if (habit != null) {
          // 提醒未成功排入系统时提示
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
  /// 打卡操作进行中标志（双击/连点防抖——toggle 语义下连点
  /// 会变成"打卡+取消"，且并发写入可致重复记录）
  bool _toggling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final done = await db.isHabitDone(widget.habit.id, AppClock.now());
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
        onPressed: _toggling
            ? null
            : () async {
                // 双击/连点防抖——toggle 语义下连点会变成
                // "打卡+取消"；_toggling 置位未触发重建前，第二次点击
                // 仍可能进入本闭包，故闭包内再守卫一次
                if (_toggling) return;
                // 批4-4：习惯打卡补触觉反馈（此前无）
                Haptics.light();
                _toggling = true;
                if (mounted) setState(() {});
                try {
                  // 打卡/取消打卡都是 toggle 语义，带撤销条（误触可恢复）
                  final willDone = !_doneToday;
                  await db.checkHabit(widget.habit.id, AppClock.now());
                  // 打卡/取消后重排习惯提醒——已打卡日期不再排
                  //（取消打卡后当天提醒恢复）
                  await ref
                      .read(reminderSchedulerProvider)
                      .scheduleHabitReminder(widget.habit);
                  // 习惯打卡数据变更通知
                  bumpDataVersion(ref);
                  _load();
                  if (!context.mounted) return;
                  showAppSnackBar(
                    context,
                    willDone ? '已打卡「${widget.habit.name}」' : '已取消今日打卡',
                    actionLabel: '撤销',
                    onAction: () async {
                      await db.checkHabit(widget.habit.id, AppClock.now());
                      await ref
                          .read(reminderSchedulerProvider)
                          .scheduleHabitReminder(widget.habit);
                      bumpDataVersion(ref);
                      _load();
                    },
                    icon: willDone ? Icons.check_circle_outline : Icons.undo,
                  );
                } finally {
                  _toggling = false;
                }
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
        AppClock.at(
          AppClock.now().year,
          AppClock.now().month,
          AppClock.now().day,
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
                        () => time = AppClock.at(
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
    // 习惯数据变更通知
    bumpDataVersion(ref);
    final updated = await db.getHabit(habit.id);
    if (updated != null) {
      // 提醒未成功排入系统时提示
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
