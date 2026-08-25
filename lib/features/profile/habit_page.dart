import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/haptics_service.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';

/// 可选的习惯图标（emoji，按习惯场景挑选，新建/编辑共用）
const _habitIcons = <String>[
  '📚', '🏃', '💪', '🧘', '😴', '💧', '🥗',
  '🍎', '💊', '🦷', '✍️', '🎨', '🎸', '🎹', '📖',
  '💻', '📱', '💰', '🛒', '🧹', '🚶', '🚴', '🏊',
  '⚽', '🏀', '🎾', '🏸', '🧠', '💡', '🌅', '🌙',
  '☀️', '🐕', '🌱', '🎯', '🚭', '🌊', '🍵', '🥕',
];

/// 习惯列表行高（itemExtent 与深链滚动定位共用同一常量）
const _tileExtent = 112.0;

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
            (idx * _tileExtent).clamp(0.0, _scroll.position.maxScrollExtent),
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
              itemExtent: _tileExtent,
              itemCount: _habits.length,
              itemBuilder: (context, index) {
                final habit = _habits[index];
                return _HabitTile(
                  habit: habit,
                  highlight: habit.id == widget.initialHabitId,
                  onRefresh: _load,
                  onDelete: () async {
                    // 删除习惯前确认（误触即丢打卡记录）
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
                    final scheduler = ref.read(reminderSchedulerProvider);
                    // 删除前缓存习惯与其全部打卡记录，撤销条可完整恢复
                    final records = await db.getHabitRecords(habit.id);
                    // 先取消已排的每日提醒，避免删除后仍收到通知
                    await scheduler.cancelHabitReminder(habit.id);
                    await db.deleteHabit(habit.id);
                    // 删除动作音效
                    SoundService.instance.play(SoundKind.delete);
                    // 习惯数据变更通知
                    bumpDataVersion(ref);
                    _load();
                    if (!context.mounted) return;
                    showAppSnackBar(
                      context,
                      '已删除「${habit.name}」',
                      actionLabel: '撤销',
                      onAction: () async {
                        // 撤销删除 = 恢复，配恢复音效
                        SoundService.instance.play(SoundKind.reopen);
                        await db.restoreHabit(habit, records);
                        await scheduler.scheduleHabitReminder(habit);
                        bumpDataVersion(ref);
                        _load();
                      },
                      icon: Icons.delete_outline,
                    );
                  },
                );
              },
            ),
    );
  }

  Future<void> _addHabit() async {
    final controller = TextEditingController();
    var remind = false;
    String? icon;
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
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  // 名称输入后刷新对话框，让「创建」按钮的禁用态即时更新
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(hintText: '如：阅读、健身、早睡'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '图标',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    if (icon == null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '请点选一个图标',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(c).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                _HabitIconField(
                  selected: icon,
                  onSelected: (v) => setDialogState(() => icon = v),
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
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              // 名称与图标均必填：未选图标/名称为空时禁用，避免
              // 创建出默认星星等"不明所以"的习惯
              onPressed:
                  (icon == null || controller.text.trim().isEmpty)
                  ? null
                  : () => Navigator.pop(
                      c,
                      _HabitDraft(
                        controller.text.trim(),
                        icon!,
                        remind ? time : null,
                      ),
                    ),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (draft != null) {
      final db = ref.read(dbProvider);
      final id = await db.insertHabit(
        draft.name,
        draft.icon,
        draft.reminderTime,
      );
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

/// 新建习惯草稿（名称 + 图标 + 提醒时间）
class _HabitDraft {
  final String name;
  final String icon;
  final DateTime? reminderTime;

  _HabitDraft(this.name, this.icon, this.reminderTime);
}

/// 图标选择弹窗（从表单点击进入）：网格点选即返回所选，取消/点外部关闭
Future<String?> showHabitIconPicker(
  BuildContext context, {
  String? selected,
}) {
  return showDialog<String>(
    context: context,
    builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      // 小屏/横屏自适应：宽不超屏宽 85%、高不超屏高一半
      //（GridView 可滚动，空间不足时只缩不放导致溢出）
      final size = MediaQuery.sizeOf(c);
      return AlertDialog(
        title: const Text('选择图标'),
        content: SizedBox(
          width: math.min(320.0, size.width * 0.85),
          height: math.min(330.0, size.height * 0.5),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: _habitIcons.length,
            itemBuilder: (context, i) {
              final ic = _habitIcons[i];
              final isSel = ic == selected;
              return InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: () => Navigator.pop(c, ic),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSel
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: isSel
                        ? Border.all(color: scheme.primary, width: 2)
                        : null,
                  ),
                  child: Text(ic, style: const TextStyle(fontSize: 26)),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      );
    },
  );
}

/// 表单内的紧凑图标选择入口：点击弹出独立选择弹窗，
/// 避免把整个图标网格挤在新建/编辑表单里
class _HabitIconField extends StatelessWidget {
  const _HabitIconField({required this.selected, required this.onSelected});

  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showHabitIconPicker(context, selected: selected);
        if (picked != null) onSelected(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: scheme.surface,
              child: selected == null
                  ? Icon(
                      Icons.emoji_emotions_outlined,
                      size: 18,
                      color: Colors.grey.shade500,
                    )
                  : Text(selected!, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: 10),
            Text(
              selected == null ? '选择图标' : '更换图标',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
            const Spacer(),
            Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade500),
          ],
        ),
      ),
    );
  }
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
  int _streak = 0;
  int _total = 0;
  /// 近 7 天（含今天）每天是否已打卡，索引 0=6 天前 … 6=今天
  final List<bool> _recent7 = List.filled(7, false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final now = AppClock.now();
    final done = await db.isHabitDone(widget.habit.id, now);
    final records = await db.getHabitRecords(widget.habit.id);
    // 已打卡日期集合（日历日归一，DST 安全）
    final doneDays = <DateTime>{
      for (final r in records) AppClock.startOfDay(AppClock.asApp(r.date)),
    };
    final today = AppClock.startOfDay(now);
    // 连续打卡：今天已打卡从今天起数，否则从昨天起数
    var cursor = done ? today : AppClock.addCalendarDays(today, -1);
    var streak = 0;
    while (doneDays.contains(cursor)) {
      streak++;
      cursor = AppClock.addCalendarDays(cursor, -1);
    }
    // 近 7 天打卡情况（索引 0=6 天前 … 6=今天）
    final recent = List<bool>.filled(7, false);
    for (var d = 0; d < 7; d++) {
      recent[6 - d] = doneDays.contains(AppClock.addCalendarDays(today, -d));
    }
    if (mounted) {
      setState(() {
        _doneToday = done;
        _streak = streak;
        _total = records.length;
        for (var i = 0; i < 7; i++) {
          _recent7[i] = recent[i];
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remindText = widget.habit.reminderTime == null
        ? null
        : '每日 ${DateUtilsEx.timeCn(widget.habit.reminderTime!)} 提醒';
    return ListTile(
      tileColor: widget.highlight
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: _doneToday
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        child: Text(widget.habit.icon, style: const TextStyle(fontSize: 22)),
      ),
      title: Text(
        widget.habit.name,
        style: TextStyle(
          fontWeight: _doneToday ? FontWeight.bold : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _doneToday ? '今日已打卡' : '今日未打卡',
            style: TextStyle(
              fontSize: 12,
              color: _doneToday ? scheme.primary : Colors.grey,
            ),
          ),
          Text(
            '连续打卡 $_streak 天 · 共打卡 $_total 天'
            '${remindText == null ? '' : ' · $remindText'}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (var d = 0; d < 7; d++) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _recent7[d]
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    // 最右一格 = 今天，红圈标注
                    border: d == 6
                        ? Border.all(color: scheme.error, width: 1)
                        : null,
                  ),
                ),
                if (d < 6) const SizedBox(width: 4),
              ],
              const SizedBox(width: 8),
              Text(
                '近7天',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              ),
            ],
          ),
        ],
      ),
      onTap: _toggling ? null : _toggle,
      trailing: IconButton(
        icon: Icon(
          _doneToday ? Icons.check_circle : Icons.radio_button_unchecked,
          color: _doneToday ? Theme.of(context).colorScheme.primary : null,
        ),
        onPressed: _toggling ? null : _toggle,
      ),
      onLongPress: () => _showActions(),
    );
  }

  /// 打卡/取消打卡（行主体点击与行尾图标共用，toggle 语义带撤销条）
  Future<void> _toggle() async {
    final db = ref.read(dbProvider);
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
      // 打卡/取消打卡配动作音效（完成/恢复，与任务完成一致）
      SoundService.instance.play(
        willDone ? SoundKind.complete : SoundKind.reopen,
      );
      await db.checkHabit(widget.habit.id, AppClock.now());
      // 打卡/取消后重排习惯提醒——已打卡日期不再排
      //（取消打卡后当天提醒恢复）
      await ref
          .read(reminderSchedulerProvider)
          .scheduleHabitReminder(widget.habit);
      // 习惯打卡数据变更通知
      bumpDataVersion(ref);
      _load();
      if (!mounted) return;
      showAppSnackBar(
        context,
        willDone ? '已打卡「${widget.habit.name}」' : '已取消今日打卡',
        actionLabel: '撤销',
        onAction: () async {
          // 撤销打卡 = 恢复，配恢复音效
          SoundService.instance.play(SoundKind.reopen);
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
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑习惯'),
              onTap: () {
                Navigator.pop(c);
                _editHabit();
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

  /// 编辑习惯（长按 → 编辑习惯）：名称 + 图标一个弹窗（仿新建弹窗），
  /// 有变化的字段才写库
  Future<void> _editHabit() async {
    final habit = widget.habit;
    final nameCtrl = TextEditingController(text: habit.name);
    var icon = habit.icon;
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: const Text('编辑习惯'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '如：阅读、健身、早睡'),
                ),
                const SizedBox(height: 12),
                Text(
                  '图标',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 6),
                _HabitIconField(
                  selected: icon,
                  onSelected: (v) => setDialogState(() => icon = v),
                ),
              ],
            ),
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
    final newName = nameCtrl.text.trim();
    // 注意：不在 dialog 返回后立即 dispose controller——弹窗退出动画期间
    // TextField 仍在树中监听，dispose 会触发 "used after being disposed"
    if (saved != true) return;
    final db = ref.read(dbProvider);
    if (newName.isNotEmpty && newName != habit.name) {
      await db.updateHabitName(habit.id, newName);
    }
    if (icon != habit.icon) {
      await db.updateHabitIcon(habit.id, icon);
    }
    // 习惯数据变更通知（统计页热力图随之刷新）
    bumpDataVersion(ref);
    widget.onRefresh();
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
