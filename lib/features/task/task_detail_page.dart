import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/theme/task_colors.dart';
import 'package:zhuoluo/core/theme/theme.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/reminder_scheduler.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 任务详情页（7 区块，自动保存）
class TaskDetailPage extends ConsumerStatefulWidget {
  const TaskDetailPage({super.key, required this.taskId});

  final int taskId;

  @override
  ConsumerState<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends ConsumerState<TaskDetailPage>
    with WidgetsBindingObserver {
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  bool _noteEditMode = true;
  late Task? _task;
  List<Reminder> _reminders = [];
  List<Task> _subTasks = [];
  /// 子任务"今天完成"状态（重复子任务按实例表判断）
  final Map<int, bool> _subTasksDone = {};
  /// 重复任务：今天实例是否已完成
  bool _instanceDoneToday = false;
  /// 重复任务今天是否命中规则（非规则日无"今天实例"可完成）
  bool _todayHas = true;
  bool _loaded = false;
  /// _load 请求序号——丢弃过期请求结果，防止旧数据覆盖新状态
  /// （用户输入标题/备注时，较慢的旧 _load 会把输入框回滚为旧值）
  int _loadSeq = 0;

  /// A13：底部面板统一收口——打开前收起键盘，**关闭后再收一次**：
  /// Flutter 的 ModalRoute 关闭时会把焦点归还给之前聚焦的节点（标题
  /// 输入框），只在打开前 unfocus 挡不住归还，光标会一直留在标题框闪烁
  Future<T?> _showSheet<T>({
    required Widget Function(BuildContext) builder,
    bool isScrollControlled = false,
  }) async {
    FocusScope.of(context).unfocus();
    final r = await showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
    );
    if (mounted) FocusScope.of(context).unfocus();
    return r;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A13：进入详情页首帧主动收焦点——否则标题框可能自动聚焦，
    // 光标一直闪烁（即使用户不编辑）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusManager.instance.primaryFocus?.unfocus();
    });
    _load();
  }

  /// A13：键盘可见性变化——**键盘收起即失焦**（用户期望：编辑完按
  /// 返回键收起键盘后，光标不再留在输入框闪烁）。
  /// 必须用**边沿检测 + 延迟确认**：键盘弹出动画的初始帧 viewInsets 仍为
  /// 0，无条件 `== 0` 判定会把刚弹出的键盘误收回（用户无法输入）
  double _lastInsets = 0;
  Timer? _metricsDebounce;

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    // 必须读 FlutterView 实时值（MetricsChanged 时已更新）——
    // MediaQuery 是下一帧 build 才同步，读它拿到的还是旧值，
    // 键盘收起时边沿检测（>0→0）永远不成立，光标无法失焦
    final insets = View.of(context).viewInsets.bottom;
    if (_lastInsets > 0 && insets == 0) {
      _metricsDebounce?.cancel();
      _metricsDebounce = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (View.of(context).viewInsets.bottom == 0) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      });
    }
    _lastInsets = insets;
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final db = ref.read(dbProvider);
    final task = await db.getTask(widget.taskId);
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _task = task;
      // A13：文本相同不重新赋值——controller.text setter 每次都会重置
      // 光标/选区到末尾，编辑中触发 _load 会导致输入框跳动回编辑态；
      // **_inputDirty（输入/防抖窗口内）时跳过，防止把用户输入回滚成
      // DB 旧值（表现为"输入后没保存"）**
      if (!_inputDirty && task?.title != _titleController.text) {
        _titleController.text = task?.title ?? '';
      }
      if (!_inputDirty && task?.note != _noteController.text) {
        _noteController.text = task?.note ?? '';
      }
    });
    if (task != null) {
      _reminders = await db.getReminders(task.id);
      if (!mounted || seq != _loadSeq) return;
      _subTasks = await db.getSubTasks(task.id);
      if (!mounted || seq != _loadSeq) return;
      // 子任务完成状态——重复子任务按今日实例完成记录判断
      // （此前一律用 completedAt，重复子任务今天已完成仍显示未完成）
      final now = AppClock.now();
      final today = AppClock.at(now.year, now.month, now.day);
      for (final s in _subTasks) {
        _subTasksDone[s.id] = s.rrule.isNotEmpty
            ? await db.isInstanceCompleted(s.id, today)
            : s.completedAt != null;
        if (!mounted || seq != _loadSeq) return;
      }
      if (task.rrule.isNotEmpty) {
        _instanceDoneToday = await db.isInstanceCompleted(task.id, today);
        if (!mounted || seq != _loadSeq) return;
        _todayHas = (await db.expandTaskForDate(task, today)).isNotEmpty;
      }
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() => _loaded = true);
  }

  TasksController get _notifier => ref.read(tasksControllerProvider.notifier);

  @override
  void dispose() {
    // C8-1：返回页面时立即 flush 未保存的标题/备注（此前依赖防抖 active
    // + 比较条件——条件恒 false 导致修改静默丢失）。
    // A13：改用 _inputDirty 判定 + 无条件保存 controller 当前值
    _saveDebounce?.cancel();
    if (_inputDirty) {
      _inputDirty = false;
      final t = _task;
      if (t != null) {
        final title = _titleController.text;
        final note = _noteController.text;
        _notifier.updateTaskFields(
          t.id,
          TasksCompanion(
            title: Value(title),
            note: Value(note),
            hasNote: Value(note.isNotEmpty),
          ),
        );
      }
    }
    _metricsDebounce?.cancel();
    _titleController.dispose();
    _noteController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 先检查加载标志再访问 _task：_load 异步完成前（导航动画第一帧）
    // 直接访问 late _task 会抛 LateInitializationError（深链/快速进入时）
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final t = _task;
    // 任务被其他入口删除后显示空态（此前无限转圈）
    if (t == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.help_outline, size: 48, color: Colors.grey),
              SizedBox(height: 12),
              Text('任务不存在或已被删除', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    final done = t.rrule.isNotEmpty ? _instanceDoneToday : t.completedAt != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(t),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 区块1：标题 + 完成
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                icon: Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: done ? Theme.of(context).colorScheme.primary : null,
                  size: 28,
                ),
                onPressed: () async {
                  // 重复任务今天不是规则日 → 无"今天实例"可完成
                  // （防止写入不存在的实例记录）
                  if (t.rrule.isNotEmpty && !_todayHas) {
                    showAppSnackBar(
                      context,
                      '今天没有「${t.title}」的实例',
                      icon: Icons.event_busy,
                    );
                    return;
                  }
                  if (done) {
                    await _notifier.reopenTask(t.id);
                  } else {
                    // C1-2：完成未来系列实例时明确提示实际日期
                    // （界面"今天"状态不变，否则看起来"点了没反应"）
                    final doneDay = await _notifier.completeTask(t.id);
                    if (context.mounted &&
                        t.rrule.isNotEmpty &&
                        doneDay != null &&
                        !DateUtilsEx.sameDay(doneDay, AppClock.now())) {
                      showAppSnackBar(
                        context,
                        '已提前完成 ${DateUtilsEx.dateCn(doneDay)} 的实例',
                        icon: Icons.check_circle_outline,
                      );
                    }
                  }
                  _load();
                },
              ),
              Expanded(
                child: TextField(
                  controller: _titleController,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  // A13：标题输入框圆角矩形（此前无边框仅填充；
                  // 保留主题 filled，聚焦时蓝色圆角高亮）
                  decoration: InputDecoration(
                    hintText: '任务标题',
                    border: OutlineInputBorder(
                      borderRadius: AppRadius.field,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: AppRadius.field,
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5,
                      ),
                    ),
                  ),
                  // A13：键盘"完成"键 → 失焦（配合 didChangeMetrics：
                  // 无论按完成键还是返回键收起键盘，光标都不再停留）
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  onChanged: (v) => _saveTitle(v),
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          // 区块2：主属性
          _ListTileRow(
            icon: Icons.playlist_play,
            label: '清单',
            value: _listName(t.listId),
            onTap: () => _pickList(t),
          ),
          _ListTileRow(
            icon: Icons.grid_view,
            label: '象限',
            // C2-2：未分类（quadrant>=4）不再伪装成"一般"
            value: t.quadrant >= 0 && t.quadrant < 4
                ? quadrantNames[t.quadrant]
                : '未分类',
            onTap: () => _pickQuadrant(t),
          ),
          _ListTileRow(
            icon: Icons.palette_outlined,
            label: '颜色',
            value: _colorText(t),
            onTap: () => _pickColor(t),
          ),
          _ListTileRow(
            icon: Icons.event,
            label: '计划时间',
            value: _planText(t),
            onTap: () => _pickPlanTime(t),
          ),
          _ListTileRow(
            icon: Icons.flag_outlined,
            label: '截止时间',
            value: t.dueTime == null ? '未设置' : _dateTimeText(t.dueTime!),
            onTap: () => _pickDueTime(t),
          ),
          // 区块3：提醒
          const Padding(
            padding: EdgeInsets.only(top: 16, bottom: 4),
            child: Text('提醒', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (_reminders.isEmpty)
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('无提醒', style: TextStyle(color: Colors.grey)),
            )
          else
            for (final r in _reminders)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_outlined),
                title: Text(_reminderText(r)),
                // 全天任务：点击可修改提醒时刻
                // 非全天任务点击给提示（此前样式相同但点击无反应）
                onTap: _task!.isAllDay
                    ? () => _editReminderAt(r)
                    : () => showAppSnackBar(
                          context,
                          '提醒时刻仅全天任务可调整',
                          icon: Icons.info_outline,
                        ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _removeReminder(r),
                ),
              ),
          TextButton.icon(
            onPressed: _addReminder,
            icon: const Icon(Icons.add),
            label: const Text('添加提醒'),
          ),
          // 区块4：重复
          _ListTileRow(
            icon: Icons.repeat,
            label: '重复',
            value: t.rrule.isEmpty ? '不重复' : _rruleText(t.rrule),
            onTap: () => _pickRepeat(t),
          ),
          // 重复任务：实例操作（完成/改期/跳过本次）
          if (t.rrule.isNotEmpty) ...[
            // 今天非规则日 → 无"今天实例"可完成（防止写入不存在
            // 的实例记录；改期/跳过本次仍可用）
            if (_todayHas)
              _ListTileRow(
                icon: Icons.check_circle_outline,
                label: done ? '撤销完成本次' : '完成本次',
                value: done ? '今天已完成' : '今天待完成',
                onTap: () async {
                  await _notifier.completeTask(t.id);
                  _load();
                  // C4-3：与任务页一致——完成/撤销本次带撤销条
                  if (context.mounted) {
                    showAppSnackBar(
                      context,
                      done ? '已撤销今天的完成' : '已完成今天的实例',
                      actionLabel: '撤销',
                      onAction: () => _notifier.completeTask(t.id),
                      icon: done ? Icons.undo : Icons.check_circle_outline,
                    );
                  }
                },
              ),
            _ListTileRow(
              icon: Icons.event_repeat,
              label: '改期本次',
              value: DateUtilsEx.dateCn(TasksController.currentInstanceDate(t)),
              onTap: () => _rescheduleInstance(t),
            ),
            _ListTileRow(
              icon: Icons.skip_next,
              label: '跳过本次',
              value: '不再安排当天实例',
              onTap: () async {
                final instDay = TasksController.currentInstanceDate(t);
                await _notifier.skipInstance(t.id, instDay);
                _load();
                // C4-2：与其余入口一致——跳过带撤销条
                if (context.mounted) {
                  showAppSnackBar(
                    context,
                    '已跳过 ${DateUtilsEx.dateCn(instDay)} 的实例',
                    actionLabel: '撤销',
                    onAction: () => _notifier.unskipInstance(t.id, instDay),
                    icon: Icons.skip_next,
                  );
                }
              },
            ),
          ],
          // 区块5：子任务
          const Padding(
            padding: EdgeInsets.only(top: 16, bottom: 4),
            child: Text('子任务', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final s in _subTasks)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                (_subTasksDone[s.id] ?? false)
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: (_subTasksDone[s.id] ?? false)
                    ? Theme.of(context).colorScheme.primary
                    : null,
                size: 20,
              ),
              title: Text(
                s.title,
                style: TextStyle(
                  decoration: (_subTasksDone[s.id] ?? false)
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _deleteSubTask(s),
              ),
              onTap: () async {
                if (_subTasksDone[s.id] ?? false) {
                  await _notifier.reopenTask(s.id);
                } else {
                  await _notifier.completeTask(s.id);
                }
                _load();
              },
            ),
          TextButton.icon(
            onPressed: _addSubTask,
            icon: const Icon(Icons.add),
            label: const Text('添加子任务'),
          ),
          // 区块6：备注（编辑/预览切换，I2 Markdown 渲染）
          Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 4),
                child: Text(
                  '备注',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('编辑')),
                  ButtonSegment(value: false, label: Text('预览')),
                ],
                selected: {_noteEditMode},
                onSelectionChanged: (s) =>
                    setState(() => _noteEditMode = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          if (_noteEditMode)
            TextField(
              controller: _noteController,
              maxLines: 6,
              minLines: 3,
              decoration: const InputDecoration(
                hintText: '支持 Markdown 格式的备注',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => _saveNote(v),
            )
          else
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 100),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(4),
              ),
              child: t.note.isEmpty
                  ? Text('无备注', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
                  : MarkdownBody(data: t.note),
            ),
          const SizedBox(height: 16),
          // 区块7：时间与删除
          Text(
            '创建于 ${DateUtilsEx.dateCn(t.createdAt)}',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (t.completedAt != null)
            Text(
              '完成于 ${DateUtilsEx.dateCn(t.completedAt!)}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          if (done)
            TextButton(
              onPressed: () async {
                await _notifier.reopenTask(t.id);
                _load();
              },
              child: const Text('重新打开'),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _listName(int listId) {
    final lists = ref.read(tasksControllerProvider).lists;
    final l = lists.where((e) => e.id == listId).firstOrNull;
    return l?.name ?? '收件箱';
  }

  String _reminderText(Reminder r) {
    // 全天任务：提醒 = 当天某时刻（提前量概念已废弃，旧数据也忽略提前量显示）
    if (_task!.isAllDay) {
      final m = r.remindAtMinutes ?? 540; // 默认 09:00
      return '${_repeatLabel()} '
          '${DateUtilsEx.timeCn(DateTime(2024, 1, 1, m ~/ 60, m % 60))} 提醒';
    }
    final m = r.remindMinutesBefore;
    String ahead;
    if (m == 0) {
      ahead = '准时提醒';
    } else {
      final d = m ~/ 1440;
      final h = (m % 1440) ~/ 60;
      final mm = m % 60;
      final parts = <String>[];
      if (d > 0) parts.add('$d 天');
      if (h > 0) parts.add('$h 小时');
      if (mm > 0) parts.add('$mm 分钟');
      ahead = '提前 ${parts.join(' ')}';
    }
    return ahead;
  }

  /// 重复任务的频率标签（"每天"/"每周"/"每月"等）
  String _repeatLabel() {
    final t = _task;
    if (t == null || t.rrule.isEmpty) return '';
    final rule = RruleService.instance.parse(t.rrule);
    switch (rule.freq) {
      case 'DAILY':
        return rule.interval == 1 ? '每天' : '每 ${rule.interval} 天';
      case 'WEEKLY':
        return rule.interval == 1 ? '每周' : '每 ${rule.interval} 周';
      case 'MONTHLY':
        return rule.interval == 1 ? '每月' : '每 ${rule.interval} 月';
      case 'YEARLY':
        return '每年';
    }
    return '';
  }

  String _rruleText(String rrule) {
    final rule = RruleService.instance.parse(rrule);
    switch (rule.freq) {
      case 'DAILY':
        return rule.interval == 1 ? '每天' : '每 ${rule.interval} 天';
      case 'WEEKLY':
        return rule.interval == 1 ? '每周' : '每 ${rule.interval} 周';
      case 'MONTHLY':
        return rule.byMonthDay != null
            ? '每月 ${rule.byMonthDay!.join("、")} 号'
            : (rule.interval == 1 ? '每月' : '每 ${rule.interval} 月');
      case 'YEARLY':
        return '每年';
    }
    return rrule;
  }

  /// 标题/备注保存防抖——每敲一个字符就触发 updateTaskFields
  /// （内部会取消全部通知→写库→全量重载→重新排期）非常浪费
  Timer? _saveDebounce;

  /// A13：输入保护标志——标题/备注有未落库的修改时置 true（onChanged），
  /// 防抖保存执行后置 false。`_load` 看到 dirty 时**不回滚输入框文本**：
  /// 否则用户输入后在防抖窗口内触发 _load（如改计划时间面板关闭），
  /// controller 会被重置为 DB 旧值，输入的文字从界面消失（"没保存"）
  bool _inputDirty = false;

  void _scheduleSave(String title, String note) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      final t = _task;
      if (t == null) return;
      // A13：**无条件保存快照**——此前 `title != t.title` 比较恒为 false：
      // _saveTitle 已把 _task 同步更新为输入值，防抖回调里两者必然相等，
      // 导致 updateTaskFields 从不执行、修改永远不落库（"输入后没保存"）
      _inputDirty = false;
      _notifier.updateTaskFields(
        t.id,
        TasksCompanion(
          title: Value(title),
          note: Value(note),
          hasNote: Value(note.isNotEmpty),
        ),
      );
    });
  }

  void _saveTitle(String v) {
    if (v == _task!.title) return;
    _inputDirty = true;
    setState(() => _task = _task!.copyWith(title: v));
    _scheduleSave(v, _task!.note);
  }

  void _saveNote(String v) {
    if (v == _task!.note) return;
    _inputDirty = true;
    setState(() => _task = _task!.copyWith(note: v, hasNote: v.isNotEmpty));
    _scheduleSave(_task!.title, v);
  }

  Future<void> _pickList(Task t) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final lists = ref.read(tasksControllerProvider).lists;
    final id = await _showSheet<int>(
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
                  trailing: l.id == t.listId ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, l.id),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (id != null && id != t.listId) {
      await _notifier.updateTaskFields(t.id, TasksCompanion(listId: Value(id)));
      // await 后 mounted 检查（弹窗期间退出页面避免 setState-after-dispose）
      if (mounted) setState(() => _task = t.copyWith(listId: id));
    }
  }

  Future<void> _pickQuadrant(Task t) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final q = await _showSheet<int>(
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 4; i++)
              ListTile(
                leading: Icon(Icons.circle, color: quadrantColors[i], size: 16),
                title: Text(quadrantNames[i]),
                trailing: t.quadrant == i ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(c, i),
              ),
            // C2-2：未分类选项（此前选择器无该项，未分类任务"都没勾选"）
            ListTile(
              leading: const Icon(Icons.label_off_outlined, size: 16),
              title: const Text('未分类'),
              trailing: t.quadrant >= 4 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, 4),
            ),
          ],
        ),
      ),
    );
    if (q != null && q != t.quadrant) {
      await _notifier.updateTaskFields(
        t.id,
        TasksCompanion(quadrant: Value(q)),
      );
      // await 后 mounted 检查
      if (mounted) setState(() => _task = t.copyWith(quadrant: q));
    }
  }

  String _planText(Task t) {
    final ps = t.planStart;
    if (ps == null) return '未设置';
    final pe = t.planEnd;
    if (t.isAllDay) {
      return DateUtilsEx.dateCn(ps);
    }
    final peText = pe == null
        ? ''
        : '-${DateUtilsEx.timeCn(pe)}'
              '${DateUtilsEx.sameDay(ps, pe) ? '' : ' (${DateUtilsEx.dateCn(pe)})'}';
    return '${DateUtilsEx.dateCn(ps)} '
        '${DateUtilsEx.timeCn(ps)}$peText';
  }

  String _dateTimeText(DateTime dt) =>
      '${DateUtilsEx.dateCn(dt)} ${DateUtilsEx.timeCn(dt)}';

  /// 计划时间选择：开始日期+时间、结束日期+时间（支持跨天）
  String _colorText(Task t) {
    if (t.color.isEmpty) return '默认';
    final brightness = Theme.of(context).brightness;
    final c = TaskColors.colorOf(t.color, brightness);
    return c == null ? '默认' : '已设置';
  }

  Future<void> _pickColor(Task t) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final brightness = Theme.of(context).brightness;
    final selected = await _showSheet<String>(
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择颜色',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 14,
                runSpacing: 12,
                children: [
                  // 默认（无颜色）
                  InkWell(
                    onTap: () => Navigator.pop(c, ''),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: t.color.isEmpty
                              ? Theme.of(c).colorScheme.primary
                              : Colors.grey.shade400,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: t.color.isEmpty
                            ? Theme.of(c).colorScheme.primary
                            : Colors.grey,
                      ),
                    ),
                  ),
                  for (final key in TaskColors.keys)
                    InkWell(
                      onTap: () => Navigator.pop(c, key),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: TaskColors.colorOf(key, brightness),
                          border: Border.all(
                            color: t.color == key
                                ? Theme.of(c).colorScheme.primary
                                : Colors.grey.shade400,
                            width: 2,
                          ),
                        ),
                        child: t.color == key
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: TaskColors.textOn(
                                  TaskColors.colorOf(key, brightness)!,
                                ),
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && selected != t.color) {
      await _notifier.updateTaskFields(
        t.id,
        TasksCompanion(color: Value(selected)),
      );
      // await 后 mounted 检查
      if (mounted) setState(() => _task = t.copyWith(color: selected));
    }
  }

  Future<void> _pickPlanTime(Task t) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    // 底部表单：日期/时间/开始/结束分开，开始时间可留空（=全天任务）
    final result = await _showSheet<(DateTime, DateTime?, bool)>(
      isScrollControlled: true,
      builder: (c) => _PlanTimeSheet(
        initialStart: t.planStart,
        initialEnd: t.planEnd,
        initialAllDay: t.isAllDay,
      ),
    );
    if (result == null || !mounted) return;
    final (start, end, isAllDay) = result;
    final planEnd = isAllDay
        ? start.add(const Duration(days: 1))
        : (end ?? start.add(const Duration(hours: 1)));
    await _notifier.updateTaskFields(
      t.id,
      TasksCompanion(
        isAllDay: Value(isAllDay),
        planStart: Value(start),
        planEnd: Value(planEnd),
      ),
    );
    // 重复任务改计划时间 = 平移系列锚点 → 统一收口清理不再命中
    // 新锚点的旧完成记录/例外（此前平移后旧记录成孤儿参与统计）
    if (t.rrule.isNotEmpty &&
        !DateUtilsEx.sameDay(t.planStart ?? start, start)) {
      final db = ref.read(dbProvider);
      final result = await db.applyRecurringChange(
        t.id,
        oldRrule: t.rrule,
        newRrule: t.rrule,
        newStart: start,
      );
      // C8-5：清理发生时有提示（此前静默删除历史完成记录）
      if (result.removedCompletions.isNotEmpty && mounted) {
        showAppSnackBar(
          context,
          '已清理 ${result.removedCompletions.length} 条不再匹配新日期的完成记录',
          icon: Icons.info_outline,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _task = t.copyWith(
        isAllDay: isAllDay,
        planStart: Value(start),
        planEnd: Value(planEnd),
      );
    });
  }

  Future<void> _pickDueTime(Task t) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final now = AppClock.now();
    final initial = t.dueTime ?? now;
    // initialDate 钳制到 [firstDate, lastDate]
    final first = DateTime(now.year - 1);
    final last = DateTime(now.year + 5);
    final clamped = initial.isBefore(first)
        ? first
        : (initial.isAfter(last) ? last : initial);
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: clamped,
      firstDate: first,
      lastDate: last,
      helpText: '选择截止日期',
    );
    if (pickedDate == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      helpText: '选择截止时间',
    );
    if (pickedTime == null || !mounted) return;
    final due = AppClock.at(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    await _notifier.updateTaskFields(t.id, TasksCompanion(dueTime: Value(due)));
    setState(() => _task = t.copyWith(dueTime: Value(due)));
  }

  Future<void> _addReminder() async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    // 偏好设置组：全天任务提醒 = 当天某时刻（"提前 N 分钟/小时/天"对全天
    // 任务无意义），走时刻面板；定时任务走提前量面板
    if (_task!.isAllDay) {
      await _addAllDayReminder();
      return;
    }
    // 偏好设置组：命中默认提醒提前量时标记"（默认）"并高亮
    final defaultMin = await ref.read(settingsProvider).getDefaultRemindMinutes();
    final choice = await _showSheet<int>(
      // 8 个选项可能超出默认最大高度，允许滚动/自适应
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in [
                (0, '准时提醒'),
                (5, '提前 5 分钟'),
                (10, '提前 10 分钟'),
                (30, '提前 30 分钟'),
                (60, '提前 1 小时'),
                (120, '提前 2 小时'),
                (1440, '提前 1 天'),
                (2880, '提前 2 天'),
                (-1, '自定义…'),
              ])
                ListTile(
                  title: Text(e.$2),
                  titleTextStyle: e.$1 == defaultMin
                      ? TextStyle(
                          color: Theme.of(c).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        )
                      : null,
                  trailing: e.$1 == defaultMin
                      ? Text(
                          '默认',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(c).colorScheme.primary,
                          ),
                        )
                      : null,
                  onTap: () {
                    if (e.$1 == -1) {
                      Navigator.pop(c);
                      _addCustomReminder();
                    } else {
                      Navigator.pop(c, e.$1);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
    if (choice != null && choice >= 0) {
      // 插入前检查：非重复任务触发时间已过则阻止；重复任务允许（明天起生效）
      if (!_checkReminderNotPast(choice)) return;
      final db = ref.read(dbProvider);
      await db.insertReminder(
        RemindersCompanion.insert(
          taskId: _task!.id,
          remindMinutesBefore: Value(choice),
        ),
      );
      await db.updateTaskHasReminder(_task!.id, true);
      await _notifier.updateTaskFields(
        _task!.id,
        const TasksCompanion(hasReminder: Value(true)),
      );
      _load();
    }
  }

  /// 全天任务提醒：当天时刻面板（提前量无意义）。
  /// 命中全天默认提醒时刻的档位标记"（默认）"并高亮；
  /// 选中后插入 remindMinutesBefore=0 + remindAtMinutes=时刻。
  Future<void> _addAllDayReminder() async {
    final defaultAt = await ref
        .read(settingsProvider)
        .getDefaultAllDayRemindAt();
    final presets = [
      (420, '早上 7:00'),
      (480, '早上 8:00'),
      (540, '早上 9:00'),
      (720, '中午 12:00'),
      (1080, '下午 6:00'),
      (1200, '晚上 8:00'),
      (1320, '晚上 10:00'),
      (-1, '自定义…'),
    ];
    final choice = await _showSheet<int>(
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in presets)
                ListTile(
                  title: Text(e.$2),
                  titleTextStyle: e.$1 == defaultAt
                      ? TextStyle(
                          color: Theme.of(c).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        )
                      : null,
                  trailing: e.$1 == defaultAt
                      ? Text(
                          '默认',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(c).colorScheme.primary,
                          ),
                        )
                      : null,
                  onTap: () {
                    if (e.$1 == -1) {
                      Navigator.pop(c);
                      _addAllDayCustomReminder();
                    } else {
                      Navigator.pop(c, e.$1);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return; // 取消
    // 插入前检查：重复任务今天已过允许（明天起生效）；非重复已过阻止
    if (!_checkReminderNotPast(0, remindAt: choice)) return;
    final db = ref.read(dbProvider);
    await db.insertReminder(
      RemindersCompanion.insert(
        taskId: _task!.id,
        remindMinutesBefore: const Value(0),
        remindAtMinutes: Value(choice),
      ),
    );
    await db.updateTaskHasReminder(_task!.id, true);
    await _notifier.updateTaskFields(
      _task!.id,
      const TasksCompanion(hasReminder: Value(true)),
    );
    _load();
  }

  /// 全天任务自定义提醒时刻（TimePicker 选择，插入后含重排）
  Future<void> _addAllDayCustomReminder() async {
    final picked = await _pickRemindAt(null);
    if (picked == null) return;
    if (!_checkReminderNotPast(0, remindAt: picked)) return;
    final db = ref.read(dbProvider);
    await db.insertReminder(
      RemindersCompanion.insert(
        taskId: _task!.id,
        remindMinutesBefore: const Value(0),
        remindAtMinutes: Value(picked),
      ),
    );
    await db.updateTaskHasReminder(_task!.id, true);
    await _notifier.updateTaskFields(
      _task!.id,
      const TasksCompanion(hasReminder: Value(true)),
    );
    _load();
  }

  /// 检查提醒触发时间是否已过。
  /// 返回 false 表示应阻止添加（非重复任务已过 / 任务无计划时间）。
  /// 重复任务今天已过 → 允许，提示从下次实例开始。
  bool _checkReminderNotPast(int remindMinutesBefore, {int? remindAt}) {
    final t = _task;
    if (t == null) return true;
    final triggerAt = reminderTriggerAt(
      t,
      remindMinutesBefore,
      remindAtMinutes: remindAt,
    );
    // 无 planStart 的任务（仅截止时间的备份兼容路径）
    // 调度器永不排期——此前 UI 放行造成"已设置但永不触发"的静默失效
    if (triggerAt == null) {
      showAppSnackBar(
        context,
        '该任务没有开始时间，提醒无法生效。请先设置开始时间。',
        icon: Icons.warning_amber_rounded,
      );
      return false;
    }
    if (!triggerAt.isBefore(AppClock.now())) return true;
    if (t.rrule.isEmpty) {
      showAppSnackBar(
        context,
        '提醒时间已过，无法设置。请修改计划时间后再设置提醒。',
        icon: Icons.warning_amber_rounded,
      );
      return false;
    }
    showAppSnackBar(
      context,
      '今天的提醒已过，将从下次实例开始提醒。',
      icon: Icons.info_outline,
    );
    return true;
  }

  /// 全天任务提醒时刻选择（当天 0 点起分钟数；null = 取消）
  Future<int?> _pickRemindAt(int? current) async {
    // 偏好设置组：全天任务默认提醒时刻（默认 540 = 09:00）
    final defAt = await ref
        .read(settingsProvider)
        .getDefaultAllDayRemindAt();
    if (!mounted) return null;
    final initial = current ?? defAt;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
      helpText: '选择提醒时刻（全天任务）',
    );
    if (picked == null) return null;
    return picked.hour * 60 + picked.minute;
  }

  /// 修改全天任务某条提醒的时刻（含重排）
  Future<void> _editReminderAt(Reminder r) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final picked = await _pickRemindAt(r.remindAtMinutes);
    if (picked == null) return;
    // 新时刻触发时间已过：非重复任务阻止；重复任务允许（明天起生效）
    if (!_checkReminderNotPast(r.remindMinutesBefore, remindAt: picked)) {
      return;
    }
    final db = ref.read(dbProvider);
    await (db.update(db.reminders)..where((x) => x.id.equals(r.id))).write(
      RemindersCompanion(remindAtMinutes: Value(picked)),
    );
    // 提醒时刻更新同样触发数据版本（遵守统一写操作约定）
    ref.read(dataVersionProvider.notifier).state++;
    final t = await db.getTask(_task!.id);
    if (t != null) {
      await ref
          .read(reminderSchedulerProvider)
          .scheduleTask(t, AppClock.now());
    }
    _load();
  }

  /// B1：自定义提醒（天/时/分组合）
  Future<void> _addCustomReminder() async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final daysCtrl = TextEditingController();
    final hoursCtrl = TextEditingController();
    final minsCtrl = TextEditingController();
    final total = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('自定义提醒（提前多久）'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: daysCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '天',
                  hintText: '0',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: hoursCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '小时',
                  hintText: '0',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: minsCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '分钟',
                  hintText: '0',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final d = int.tryParse(daysCtrl.text) ?? 0;
              final h = int.tryParse(hoursCtrl.text) ?? 0;
              final m = int.tryParse(minsCtrl.text) ?? 0;
              final total = d * 1440 + h * 60 + m;
              if (total < 0) {
                showAppSnackBar(
                  c,
                  '提前时间不能为负',
                  icon: Icons.warning_amber_rounded,
                );
                return;
              }
              Navigator.pop(c, total);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (total != null) {
      // 全天任务：提醒时刻（默认 09:00）；取消选择则放弃添加
      int? remindAt;
      if (_task!.isAllDay) {
        remindAt = await _pickRemindAt(null);
        if (remindAt == null) return;
      }
      // 插入前检查：非重复任务触发时间已过则阻止；重复任务允许（明天起生效）
      if (!_checkReminderNotPast(total, remindAt: remindAt)) return;
      final db = ref.read(dbProvider);
      await db.insertReminder(
        RemindersCompanion.insert(
          taskId: _task!.id,
          remindMinutesBefore: Value(total),
          remindAtMinutes: Value(remindAt),
        ),
      );
      await db.updateTaskHasReminder(_task!.id, true);
      // 提醒未成功排入系统（通知权限被拒等）时明确提示
      final ok = await _notifier.updateTaskFields(
        _task!.id,
        const TasksCompanion(hasReminder: Value(true)),
      );
      _load();
      if (!ok && mounted) {
        showAppSnackBar(
          context,
          '提醒已保存，但未成功排入系统：请检查通知权限',
          icon: Icons.notifications_off_outlined,
        );
      }
    }
  }

  Future<void> _removeReminder(Reminder r) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final db = ref.read(dbProvider);
    // C1：取消该提醒的全部已排通知（ID 含实例维度，按排期窗口枚举取消）
    await ref
        .read(reminderSchedulerProvider)
        .cancelReminder(_task!.id, r.id);
    await db.deleteReminder(r.id);
    final remaining = await db.getReminders(_task!.id);
    if (remaining.isEmpty) {
      await _notifier.updateTaskFields(
        _task!.id,
        const TasksCompanion(hasReminder: Value(false)),
      );
    }
    _load();
  }

  /// B2：完整重复规则自定义面板（返回 rrule + 可选的开始日期）
  Future<void> _pickRepeat(Task t) async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final result = await _showSheet<(String, DateTime?)>(
      isScrollControlled: true,
      builder: (c) =>
          RepeatRuleSheet(initialStart: t.planStart, initialRrule: t.rrule),
    );
    if (result == null) return;
    final (rrule, startDate) = result;
    if (rrule != t.rrule || startDate != null) {
      final db = ref.read(dbProvider);
      if (rrule.isNotEmpty) {
        // 开始日期：用户选的开始日期优先，否则任务原计划开始日（保持时分）
        final now = AppClock.now();
        final base = t.planStart ?? now;
        final anchor = startDate ?? base;
        // 锚点吸附：开始日期自动对齐到距锚点最近的规则命中日
        // （A13：改为 nearestHitOnOrNear——此前仅向未来吸附，周三设"每周一"
        // 会落到下周一，当前周窗口无实例导致任务从日历"消失"）
        var startDay = AppClock.at(anchor.year, anchor.month, anchor.day);
        final hit = RruleService.instance.nearestHitOnOrNear(startDay, rrule);
        if (hit != null) {
          startDay = AppClock.at(hit.year, hit.month, hit.day);
        }
        final newStart = AppClock.at(
          startDay.year,
          startDay.month,
          startDay.day,
          base.hour,
          base.minute,
        );
        final newEnd = t.planEnd == null
            ? newStart.add(const Duration(hours: 1))
            : newStart.add(t.planEnd!.difference(base));
        // 更换/新建规则前统一清理不再匹配新系列的旧完成记录与例外
        if (rrule != t.rrule) {
          await db.applyRecurringChange(
            t.id,
            oldRrule: t.rrule,
            newRrule: rrule,
            newStart: newStart,
          );
        }
        await _notifier.updateTaskFields(
          t.id,
          TasksCompanion(
            rrule: Value(rrule),
            planStart: Value(newStart),
            planEnd: Value(newEnd),
          ),
        );
        setState(() {
          _task = t.copyWith(
            rrule: rrule,
            planStart: Value(newStart),
            planEnd: Value(newEnd),
          );
        });
        // 吸附发生了：提示用户开始日期已自动调整
        if (!DateUtilsEx.sameDay(startDay, anchor) && mounted) {
          showAppSnackBar(
            context,
            '开始日期与重复规则不匹配，已自动调整到 ${DateUtilsEx.dateCn(newStart)}',
            icon: Icons.event_repeat,
          );
        }
      } else if (rrule != t.rrule) {
        // C1-3：清除重复会删除全部历史实例完成记录与例外，先确认
        final db = ref.read(dbProvider);
        final histCount = (await (db.select(
          db.taskCompletions,
        )..where((c) => c.taskId.equals(t.id)))
                .get())
            .length;
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('停止重复？'),
            content: Text(
              histCount > 0
                  ? '将删除 $histCount 条历史实例完成记录与改期记录。'
                        '要停止重复吗？'
                  : '将停止重复，任务恢复为普通任务。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('停止重复'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        // 清除重复规则 → 删除全部实例完成记录与例外（语义失效）
        await db.applyRecurringChange(
          t.id,
          oldRrule: t.rrule,
          newRrule: rrule,
        );
        await _notifier.updateTaskFields(
          t.id,
          TasksCompanion(rrule: Value(rrule)),
        );
        setState(() => _task = t.copyWith(rrule: rrule));
      }
    }
  }

  /// 重复任务：改期本次实例（写例外，原时间保持不变）
  Future<void> _rescheduleInstance(Task t) async {
    final instDay = TasksController.currentInstanceDate(t);
    final now = AppClock.now();
    final ps = t.planStart;
    final picked = await showDatePicker(
      context: context,
      initialDate: instDay,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: '改期本次到',
    );
    if (picked == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: ps?.hour ?? 9, minute: ps?.minute ?? 0),
      helpText: '选择实例时间',
    );
    if (pickedTime == null || !mounted) return;
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
    _load();
    if (mounted) {
      showAppSnackBar(
        context,
        '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
        actionLabel: '撤销',
        onAction: () {
          notifier.undoEditException(t.id, exId);
        },
        icon: Icons.event_repeat,
      );
    }
  }

  Future<void> _addSubTask() async {
    // A13：打开选项面板前收起键盘，避免选完回来仍是编辑态
    FocusScope.of(context).unfocus();
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('添加子任务'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '子任务名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (title != null && title.isNotEmpty) {
      await _notifier.addTask(
        title: title,
        parentId: _task!.id,
        listId: _task!.listId,
      );
      _load();
    }
  }

  Future<void> _deleteSubTask(Task s) async {
    // 与其余删除路径一致——带撤销条（此前直接删除无确认无撤销，
    // 误触即永久丢失）
    await _notifier.deleteTaskWithUndo(s.id);
    if (mounted) {
      showAppSnackBar(
        context,
        '已删除子任务「${s.title}」',
        actionLabel: '撤销',
        onAction: () => _notifier.undoDelete(s.id),
        icon: Icons.delete_outline,
      );
    }
    _load();
  }

  Future<void> _confirmDelete(Task t) async {
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
            '· 删除全部：删除整个系列及其全部记录',
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
        await _notifier.skipInstance(t.id, instDay);
        // 删除本次（跳过）后刷新本地快照（此前界面停留"今天待完成"）
        _load();
        if (mounted) {
          showAppSnackBar(
            context,
            '已跳过 ${DateUtilsEx.dateCn(instDay)} 的实例',
            actionLabel: '撤销',
            onAction: () => _notifier.unskipInstance(t.id, instDay),
            icon: Icons.skip_next,
          );
        }
      } else if (choice == 'all') {
        await _notifier.deleteTaskWithUndo(t.id);
        if (mounted) {
          showAppSnackBar(
            context,
            '已删除「${t.title}」整个系列',
            actionLabel: '撤销',
            onAction: () => _notifier.undoDelete(t.id),
            icon: Icons.delete_outline,
          );
          Navigator.pop(context);
        }
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除任务？'),
        content: Text('「${t.title}」及其子任务将被删除'),
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
      // D1：删除带撤销
      await _notifier.deleteTaskWithUndo(t.id);
      if (mounted) {
        showAppSnackBar(
          context,
          '已删除「${t.title}」',
          actionLabel: '撤销',
          onAction: () => _notifier.undoDelete(t.id),
          icon: Icons.delete_outline,
        );
        Navigator.pop(context);
      }
    }
  }
}

/// 计划时间表单（开始日期必填；开始时间可留空=全天；结束时间可留空=开始+1h）
class _PlanTimeSheet extends StatefulWidget {
  const _PlanTimeSheet({
    required this.initialStart,
    required this.initialEnd,
    required this.initialAllDay,
  });

  final DateTime? initialStart;
  final DateTime? initialEnd;
  final bool initialAllDay;

  @override
  State<_PlanTimeSheet> createState() => _PlanTimeSheetState();
}

class _PlanTimeSheetState extends State<_PlanTimeSheet> {
  late DateTime _startDate;
  TimeOfDay? _startTime;
  DateTime? _endDate;
  TimeOfDay? _endTime;

  @override
  void initState() {
    super.initState();
    final ps = widget.initialStart;
    final pe = widget.initialEnd;
    _startDate = ps ?? AppClock.now();
    _startTime = (ps != null && !widget.initialAllDay)
        ? TimeOfDay(hour: ps.hour, minute: ps.minute)
        : null;
    _endDate = pe;
    _endTime = pe != null
        ? TimeOfDay(hour: pe.hour, minute: pe.minute)
        : null;
  }

  Future<void> _pickDate(
    DateTime initial,
    ValueChanged<DateTime> onPicked, {
    String? help,
  }) async {
    final now = AppClock.now();
    // initialDate 钳制到 [firstDate, lastDate]（长期任务的一年
    // 前计划时间/结束时间会超界触发断言崩溃）
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
      helpText: help,
    );
    if (picked != null) onPicked(picked);
  }

  Future<void> _pickTime(
    TimeOfDay initial,
    ValueChanged<TimeOfDay> onPicked, {
    String? help,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: help,
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '计划时间',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            // 开始日期（必填）
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event, size: 20),
              title: const Text('开始日期'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(DateUtilsEx.dateCn(_startDate)),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
              onTap: () => _pickDate(
                _startDate,
                (d) => setState(() => _startDate = d),
                help: '选择计划开始日期',
              ),
            ),
            // 开始时间（可清空=全天）
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule, size: 20),
              title: const Text('开始时间'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_startTime != null) ...[
                    Text(
                      DateUtilsEx.timeCn(
                        DateTime(
                          2000,
                          1,
                          1,
                          _startTime!.hour,
                          _startTime!.minute,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: '清除（全天）',
                      onPressed: () => setState(() => _startTime = null),
                    ),
                  ] else
                    Text('全天', style: TextStyle(color: scheme.primary)),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
              onTap: () {
                // 默认预设当前系统时间（此前固定 9:00）
                final initial =
                    _startTime ?? TimeOfDay.fromDateTime(AppClock.now());
                _pickTime(
                  initial,
                  (t) => setState(() => _startTime = t),
                  help: '选择计划开始时间',
                );
              },
            ),
            if (_startTime != null) ...[
              // 结束日期（可选，默认同日）
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_repeat, size: 20),
                title: const Text('结束日期'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _endDate == null
                          ? '与开始日期相同'
                          : DateUtilsEx.dateCn(_endDate!),
                      style: TextStyle(
                        color: _endDate == null ? Colors.grey : null,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
                onTap: () => _pickDate(
                  _endDate ?? _startDate,
                  (d) => setState(() => _endDate = d),
                  help: '选择计划结束日期',
                ),
              ),
              // 结束时间（可选，默认开始+1h）
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timelapse, size: 20),
                title: const Text('结束时间'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_endTime != null) ...[
                      Text(
                        DateUtilsEx.timeCn(
                          DateTime(
                            2000,
                            1,
                            1,
                            _endTime!.hour,
                            _endTime!.minute,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: '清除（默认 1 小时）',
                        onPressed: () => setState(() => _endTime = null),
                      ),
                    ] else
                      Text(
                        '默认 1 小时',
                        style: TextStyle(color: Colors.grey),
                      ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
                onTap: () {
                  final initial = _endTime ??
                      TimeOfDay(
                        hour: (_startTime!.hour + 1) % 24,
                        minute: _startTime!.minute,
                      );
                  _pickTime(
                    initial,
                    (t) => setState(() => _endTime = t),
                    help: '选择计划结束时间',
                  );
                },
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _submit, child: const Text('确定')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final start = AppClock.at(
      _startDate.year,
      _startDate.month,
      _startDate.day,
      _startTime?.hour ?? 0,
      _startTime?.minute ?? 0,
    );
    if (_startTime == null) {
      // 全天任务
      Navigator.pop(context, (start, null, true));
      return;
    }
    if (_endTime != null) {
      final endDate = _endDate ?? _startDate;
      var end = AppClock.at(
        endDate.year,
        endDate.month,
        endDate.day,
        _endTime!.hour,
        _endTime!.minute,
      );
      // C5-3：全天转定时时，若结束时间仍是"次日 00:00"（全天任务遗留
      // 的 planEnd），视为未设置 → 按开始时间 +1 小时，
      // 否则会静默变成 15 小时跨天任务
      final nextMidnight = AppClock.at(
        start.year,
        start.month,
        start.day + 1,
      );
      if (end == nextMidnight) {
        end = start.add(const Duration(hours: 1));
      }
      if (!end.isAfter(start)) {
        showAppSnackBar(
          context,
          '结束时间必须晚于开始时间',
          icon: Icons.warning_amber_rounded,
        );
        return;
      }
      Navigator.pop(context, (start, end, false));
      return;
    }
    // 选了结束日期但未选结束时间 → 提示（此前结束日期被静默丢弃）
    if (_endDate != null) {
      showAppSnackBar(
        context,
        '已选结束日期但未选结束时间，将按开始时间 +1 小时',
        icon: Icons.info_outline,
      );
    }
    Navigator.pop(context, (start, null, false));
  }
}

class _ListTileRow extends StatelessWidget {
  const _ListTileRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// B2：重复规则自定义面板（频率/间隔/开始日期/周几/每月几号/结束条件）
class RepeatRuleSheet extends StatefulWidget {
  const RepeatRuleSheet({super.key, this.initialStart, this.initialRrule});

  /// 任务当前计划开始日（作为"开始日期"的默认值）
  final DateTime? initialStart;

  /// 任务当前重复规则（打开时恢复已有设置）
  final String? initialRrule;

  @override
  State<RepeatRuleSheet> createState() => _RepeatRuleSheetState();
}

class _RepeatRuleSheetState extends State<RepeatRuleSheet> {
  String _freq = 'none'; // none/daily/weekly/monthly/yearly
  int _interval = 1;
  Set<int> _weekdays = {1}; // 1=周一
  int _monthDay = 1;
  String _endMode = 'never'; // never/date/count
  DateTime? _until;
  int _count = 10;
  DateTime? _startDate; // null = 使用任务原计划开始日

  late final TextEditingController _intervalCtrl;
  late final TextEditingController _monthDayCtrl;
  late final TextEditingController _countCtrl;

  /// 周几代码 → 1=周一..7=周日
  static int _weekdayToInt(String s) {
    const map = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};
    return map[s] ?? 1;
  }

  @override
  void initState() {
    super.initState();
    // 恢复任务已有的重复规则
    final rule = widget.initialRrule;
    if (rule != null && rule.isNotEmpty) {
      final parsed = RruleService.instance.parse(rule);
      _freq = parsed.freq.toLowerCase();
      _interval = parsed.interval;
      if (parsed.byDay != null && parsed.byDay!.isNotEmpty) {
        _weekdays = parsed.byDay!.map(_weekdayToInt).toSet();
      }
      if (parsed.byMonthDay != null && parsed.byMonthDay!.isNotEmpty) {
        _monthDay = parsed.byMonthDay!.first;
      }
      if (parsed.until != null) {
        _endMode = 'date';
        _until = parsed.until;
      } else if (parsed.count != null) {
        _endMode = 'count';
        _count = parsed.count!;
      }
    }
    _intervalCtrl = TextEditingController(text: '$_interval');
    _monthDayCtrl = TextEditingController(text: '$_monthDay');
    _countCtrl = TextEditingController(text: '$_count');
  }

  @override
  void dispose() {
    _intervalCtrl.dispose();
    _monthDayCtrl.dispose();
    _countCtrl.dispose();
    super.dispose();
  }

  /// 当前生效的开始日期（用户选择优先，否则任务原计划开始日，再否则今天）
  DateTime get _effectiveStart =>
      _startDate ?? widget.initialStart ?? AppClock.now();

  @override
  Widget build(BuildContext context) {
    // HCI-7：键盘避让（viewInsets 动画内边距）+ 可滚动 + 最大高度限制，
    // 聚焦"每 N 天/月"或"共 N 次"输入框时确认按钮不被键盘遮挡
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '重复规则',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final e in [
                  ('none', '不重复'),
                  ('daily', '每天'),
                  ('weekly', '每周'),
                  ('monthly', '每月'),
                  ('yearly', '每年'),
                ])
                  ChoiceChip(
                    label: Text(e.$2),
                    selected: _freq == e.$1,
                    onSelected: (v) {
                      if (v) setState(() => _freq = e.$1);
                    },
                  ),
              ],
            ),
            if (_freq != 'none') ...[
              const SizedBox(height: 12),
              // 开始日期
              InkWell(
                onTap: () async {
                  final now = AppClock.now();
                  // 长期系列的开始日期可早于一年前，钳制防断言崩溃
                  final first = DateTime(now.year - 1);
                  final last = DateTime(now.year + 5);
                  final effectiveStart = _effectiveStart.isBefore(first)
                      ? first
                      : (_effectiveStart.isAfter(last) ? last : _effectiveStart);
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: effectiveStart,
                    firstDate: first,
                    lastDate: last,
                    helpText: '重复开始日期',
                  );
                  if (picked != null) {
                    setState(() => _startDate = picked);
                  }
                },
                child: Row(
                  children: [
                    const Icon(Icons.event, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    const Text('开始日期', style: TextStyle(fontSize: 14)),
                    const Spacer(),
                    Text(
                      '从 ${DateUtilsEx.dateCn(_effectiveStart)} 开始',
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 间隔：每 [N] 天/周/月/年（独立小圆角输入框，行内垂直居中）
              Row(
                children: [
                  const Text('每', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 56,
                    height: 36,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      controller: _intervalCtrl,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 15),
                      onChanged: (v) =>
                          _interval = (int.tryParse(v) ?? 1).clamp(1, 999),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(_freqLabel(), style: const TextStyle(fontSize: 14)),
                  if (_freq == 'monthly') ...[
                    const SizedBox(width: 24),
                    const Text('第', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 56,
                      height: 36,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        controller: _monthDayCtrl,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15),
                        onChanged: (v) =>
                            _monthDay = (int.tryParse(v) ?? 1).clamp(1, 31),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('号', style: TextStyle(fontSize: 14)),
                  ],
                ],
              ),
              if (_freq == 'weekly') ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 1; i <= 7; i++)
                      FilterChip(
                        label: Text(DateUtilsEx.weekdayCn[i - 1]),
                        selected: _weekdays.contains(i),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _weekdays.add(i);
                          } else if (_weekdays.length > 1) {
                            // 至少保留一天，避免空 BYDAY
                            _weekdays.remove(i);
                          }
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // 结束条件
              const Text('结束条件', style: TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
              // 三个统一样式的 chip（高度一致，不再内嵌输入框）
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('无限期'),
                    selected: _endMode == 'never',
                    onSelected: (v) {
                      if (v) setState(() => _endMode = 'never');
                    },
                  ),
                  ChoiceChip(
                    label: Text(
                      _until == null
                          ? '结束日期'
                          : '至 ${DateUtilsEx.dateCn(_until!)}',
                    ),
                    selected: _endMode == 'date',
                    onSelected: (v) async {
                      if (!v) return;
                      final now = AppClock.now();
                      // 过期 UNTIL 早于 firstDate 会触发断言崩溃，钳制到今天
                      final until = _until;
                      final last = DateTime(now.year + 5);
                      final clamped = until == null || until.isBefore(now)
                          ? now
                          : (until.isAfter(last) ? last : until);
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: clamped,
                        firstDate: now,
                        lastDate: last,
                      );
                      if (picked != null) {
                        setState(() {
                          _endMode = 'date';
                          _until = picked;
                        });
                      }
                    },
                  ),
                  ChoiceChip(
                    label: Text('共 $_count 次'),
                    selected: _endMode == 'count',
                    onSelected: (v) {
                      if (v) setState(() => _endMode = 'count');
                    },
                  ),
                ],
              ),
              // count 模式：次数输入行（与间隔输入框同款样式）
              if (_endMode == 'count') ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('共', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 56,
                      height: 36,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        controller: _countCtrl,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15),
                        onChanged: (v) =>
                            _count = (int.tryParse(v) ?? 10).clamp(1, 9999),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('次', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, ('', null)),
                  child: const Text('清除重复'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final rrule = _buildRrule();
                    // 校验：结束日期不能早于开始日期
                    final start = _startDate;
                    if (rrule.isNotEmpty &&
                        start != null &&
                        _endMode == 'date' &&
                        _until != null &&
                        _until!.isBefore(start)) {
                      showAppSnackBar(
                        context,
                        '结束日期不能早于开始日期',
                        icon: Icons.warning_amber_rounded,
                      );
                      return;
                    }
                    Navigator.pop(context, (rrule, start));
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ),
);
  }

  String _freqLabel() {
    switch (_freq) {
      case 'daily':
        return '天';
      case 'weekly':
        return '周';
      case 'monthly':
        return '月';
      case 'yearly':
        return '年';
    }
    return '';
  }

  String _buildRrule() {
    if (_freq == 'none') return '';
    final parts = <String>['FREQ=${_freq.toUpperCase()}'];
    final interval = _interval.clamp(1, 999);
    if (interval > 1) parts.add('INTERVAL=$interval');
    if (_freq == 'weekly') {
      // 恒输出 BYDAY（全选 7 天也输出），避免无 BYDAY 时被解析为默认周一
      const map = {
        1: 'MO',
        2: 'TU',
        3: 'WE',
        4: 'TH',
        5: 'FR',
        6: 'SA',
        7: 'SU',
      };
      final days = _weekdays.toList()..sort();
      parts.add('BYDAY=${days.map((d) => map[d]).join(',')}');
    }
    if (_freq == 'monthly') {
      parts.add('BYMONTHDAY=${_monthDay.clamp(1, 31)}');
    }
    if (_endMode == 'date' && _until != null) {
      final u = _until!;
      parts.add(
        'UNTIL=${u.year}${u.month.toString().padLeft(2, '0')}${u.day.toString().padLeft(2, '0')}',
      );
    } else if (_endMode == 'count') {
      parts.add('COUNT=$_count');
    }
    return parts.join(';');
  }
}
