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
import 'package:zhuoluo/features/task/plan_time_sheet.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/repeat_rule_sheet.dart';
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
  /// 重复任务：当前实例日（今天有实例→今天；否则→下一个计划实例）
  DateTime? _currentInstance;
  /// 当前实例日是否有实例（规则命中且未跳过/未改期移走）
  bool _currentHas = true;
  /// 当前实例日是否已完成
  bool _currentDone = false;
  /// 当前实例日是否被跳过（显示"已跳过"占位）
  bool _currentSkipped = false;
  /// 当前实例日被"改期本次"到的目标日期/时间（改期行/状态行显示用）
  DateTime? _currentRescheduleTarget;
  /// 当前实例改期目标日的完成记录（完成→改期后完成记录迁移到目标日，
  /// 用于状态行"已完成并改期至 X"的交代）
  bool _currentMigratedDone = false;
  /// 下一次实例日期（含例外改期目标；跳过/改期行显示用）
  DateTime? _nextInstance;
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
        // 当前实例（今天有实例→今天；否则→下一个计划实例）统一作为
        // 完成/跳过/改期本次的目标；界面据此显示实例状态
        final instDay = TasksController.currentInstanceDate(task);
        final exceptions = await db.getExceptions(task.id);
        if (!mounted || seq != _loadSeq) return;
        _currentInstance = instDay;
        _currentHas = (await db.expandTaskForDate(task, instDay)).isNotEmpty;
        if (!mounted || seq != _loadSeq) return;
        _currentDone = await db.isInstanceCompleted(task.id, instDay);
        if (!mounted || seq != _loadSeq) return;
        _currentSkipped = _isSkipped(task, instDay);
        _currentRescheduleTarget = null;
        for (final ex in exceptions) {
          if (ex.action == 'edit' &&
              DateUtilsEx.sameDay(ex.instanceDate, instDay)) {
            _currentRescheduleTarget = ex.overrideScheduledDate;
            break;
          }
        }
        // 完成→改期：完成记录迁移到目标日，据此交代"已完成并改期至 X"
        _currentMigratedDone = false;
        final reschedTo = _currentRescheduleTarget;
        if (reschedTo != null) {
          _currentMigratedDone =
              await db.isInstanceCompleted(task.id, reschedTo);
          if (!mounted || seq != _loadSeq) return;
        }
        _nextInstance = await _notifier.nextInstanceFor(task);
        if (!mounted || seq != _loadSeq) return;
      }
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() => _loaded = true);
  }

  /// 指定日期是否在 skippedDates（被"跳过本次"）
  bool _isSkipped(Task t, DateTime day) {
    final dayKey = DateUtilsEx.normalizeInstanceDate(day).toIso8601String();
    return DateUtilsEx.parseSkippedDates(t.skippedDates).contains(dayKey);
  }

  /// 当前实例标识："今天" / "下次 X"
  String _currentInstanceLabel() {
    final inst = _currentInstance;
    if (inst == null) return '无';
    final now = AppClock.now();
    final today = AppClock.at(now.year, now.month, now.day);
    return DateUtilsEx.sameDay(inst, today)
        ? '今天'
        : '下次 ${DateUtilsEx.dateCn(inst)}';
  }

  /// 当前实例三态状态文本（互斥，改期+完成/跳过并存时合并）；无状态返回 null
  String? _currentStateText() {
    final reschedTo = _currentRescheduleTarget;
    if (reschedTo != null) {
      return _currentMigratedDone
          ? '已完成并改期至 ${DateUtilsEx.dateCn(reschedTo)}'
          : '已改到 ${DateUtilsEx.dateCn(reschedTo)}';
    }
    if (_currentSkipped) return '已跳过';
    if (_currentDone) return '已完成';
    return null;
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
    final done = t.rrule.isNotEmpty ? _currentDone : t.completedAt != null;
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
                  // 重复任务当前实例日无实例（被跳过/改期移走）→ 不可完成
                  if (t.rrule.isNotEmpty && !_currentHas) {
                    showAppSnackBar(
                      context,
                      '当前实例（${_currentInstanceLabel()}）没有可完成的实例',
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
            onClear: t.dueTime == null ? null : () => _clearDueTime(t),
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
          // 重复任务：实例操作（完成/改期/跳过本次）——统一针对"当前实例"
          if (t.rrule.isNotEmpty) ...[
            // 当前实例标识 + 三态状态行
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '当前实例：${_currentInstanceLabel()}'
                '${_currentStateText() == null ? '' : '  ·  ${_currentStateText()}'}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            // 当前实例有实例 → 完成本次；被跳过/改期移走/非规则日 → 占位
            if (_currentHas)
              _ListTileRow(
                icon: Icons.check_circle_outline,
                label: done ? '撤销完成本次' : '完成本次',
                value: done ? '当前实例已完成' : '当前实例待完成',
                onTap: () async {
                  // 记录点按前状态：撤销条按此精确恢复（completeTask 是
                  // 切换语义，慢设备连点 + 未 await _load 会让 done 闭包
                  // 与实际库状态漂移）
                  final wasDone = done;
                  await _notifier.completeTask(t.id);
                  await _load();
                  // 仅"完成"弹撤销条；"撤销完成本次"本身就是撤销动作，
                  // 不再弹（避免"撤销的撤销"）
                  if (!wasDone && context.mounted) {
                    showAppSnackBar(
                      context,
                      '已完成当前实例（${_currentInstanceLabel()}）',
                      actionLabel: '撤销',
                      onAction: () async {
                        await _notifier.completeTask(t.id);
                        await _load();
                      },
                      icon: Icons.check_circle_outline,
                    );
                  }
                },
              )
            else if (_currentSkipped)
              _ListTileRow(
                icon: Icons.skip_next,
                label: '当前实例已跳过',
                value: '已跳过 ${DateUtilsEx.dateCn(_currentInstance ?? AppClock.now())}',
                onTap: () async {
                  final instDay = _currentInstance;
                  if (instDay != null) {
                    await _notifier.unskipInstance(t.id, instDay);
                    await _load();
                    if (context.mounted) {
                      showAppSnackBar(
                        context,
                        '已撤销跳过，恢复 ${DateUtilsEx.dateCn(instDay)} 的实例',
                        icon: Icons.event_busy,
                      );
                    }
                  }
                },
              )
            else
              _ListTileRow(
                icon: Icons.event_busy,
                label: '当前实例不可用',
                value: _currentRescheduleTarget != null
                    ? '已改到 ${DateUtilsEx.dateCn(_currentRescheduleTarget!)}'
                    : '${DateUtilsEx.dateCn(_currentInstance ?? AppClock.now())} '
                        '没有可完成的实例',
                onTap: () {
                  showAppSnackBar(
                    context,
                    _currentRescheduleTarget != null
                        ? '当前实例已改期到 '
                            '${DateUtilsEx.dateCn(_currentRescheduleTarget!)}'
                        : '${DateUtilsEx.dateCn(_currentInstance ?? AppClock.now())} '
                            '不在重复规则内',
                    icon: Icons.event_busy,
                  );
                },
              ),
            _ListTileRow(
              icon: Icons.event_repeat,
              label: '改期本次',
              value: _currentRescheduleTarget != null
                  ? '已改到 ${DateUtilsEx.dateCn(_currentRescheduleTarget!)} '
                      '${DateUtilsEx.timeCn(_currentRescheduleTarget!)}'
                  : DateUtilsEx.dateCn(_currentInstance ?? AppClock.now()),
              onTap: () => _rescheduleInstance(t),
            ),
            _ListTileRow(
              icon: Icons.skip_next,
              label: '跳过本次',
              value: _nextInstance != null
                  ? '下次 ${DateUtilsEx.dateCn(_nextInstance!)}'
                  : '不再安排当天实例',
              onTap: () async {
                // 改期后：跳过无意义（当前实例已移走）→ 提示而非空操作
                final reschedTo = _currentRescheduleTarget;
                if (reschedTo != null) {
                  showAppSnackBar(
                    context,
                    '当前实例已改期到 ${DateUtilsEx.dateCn(reschedTo)}，无需跳过',
                    icon: Icons.event_busy,
                  );
                  return;
                }
                final instDay = _currentInstance;
                if (instDay == null) return;
                await _notifier.skipInstance(t.id, instDay);
                await _load();
                // C4-2：跳过带撤销条；撤销后刷新详情页
                if (context.mounted) {
                  showAppSnackBar(
                    context,
                    '已跳过 ${DateUtilsEx.dateCn(instDay)} 的实例',
                    actionLabel: '撤销',
                    onAction: () async {
                      await _notifier.unskipInstance(t.id, instDay);
                      await _load();
                    },
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

  String _planText(Task t) =>
      DateUtilsEx.planRangeText(t.planStart, t.planEnd, isAllDay: t.isAllDay);

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
    final result = await _showSheet<(DateTime?, DateTime?, bool)>(
      isScrollControlled: true,
      builder: (c) => PlanTimeSheet(
        initialStart: t.planStart,
        initialEnd: t.planEnd,
        initialAllDay: t.isAllDay,
      ),
    );
    if (result == null || !mounted) return;
    final (start, end, isAllDay) = result;
    // 清除计划时间（PlanTimeSheet 底部"清除计划时间"）
    if (start == null) {
      await _clearPlanTime(t);
      return;
    }
    final planEnd = isAllDay
        ? AppClock.nextDay(start)
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

  /// 清除计划时间（planStart/planEnd → null、isAllDay → false）。
  /// 重复任务清除计划时间会丢失规则锚点 → 一并停止重复（复用"停止重复"
  /// 收口：清理不再匹配的历史完成/例外），需用户确认
  Future<void> _clearPlanTime(Task t) async {
    final db = ref.read(dbProvider);
    if (t.rrule.isNotEmpty) {
      final histCount = (await (db.select(
        db.taskCompletions,
      )..where((c) => c.taskId.equals(t.id)))
              .get())
          .length;
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('清除计划时间？'),
          content: Text(
            '重复任务清除计划时间将同时停止重复'
            '${histCount > 0 ? '并删除 $histCount 条历史完成/改期记录' : ''}。继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('清除'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      // 清理历史完成/例外，再清计划与重复规则（与"停止重复"同一收口）
      await db.applyRecurringChange(t.id, oldRrule: t.rrule, newRrule: '');
      await _notifier.updateTaskFields(
        t.id,
        TasksCompanion(
          planStart: const Value(null),
          planEnd: const Value(null),
          isAllDay: const Value(false),
          rrule: const Value(''),
        ),
      );
      if (!mounted) return;
      setState(() {
        _task = t.copyWith(
          planStart: const Value(null),
          planEnd: const Value(null),
          isAllDay: false,
          rrule: '',
        );
      });
      return;
    }
    await _notifier.updateTaskFields(
      t.id,
      TasksCompanion(
        planStart: const Value(null),
        planEnd: const Value(null),
        isAllDay: const Value(false),
      ),
    );
    if (!mounted) return;
    setState(() {
      _task = t.copyWith(
        planStart: const Value(null),
        planEnd: const Value(null),
        isAllDay: false,
      );
    });
  }

  /// 清除截止时间（dueTime → null）
  Future<void> _clearDueTime(Task t) async {
    await _notifier.updateTaskFields(
      t.id,
      TasksCompanion(dueTime: Value(null)),
    );
    if (!mounted) return;
    setState(() => _task = t.copyWith(dueTime: Value(null)));
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
          .scheduleTask(t);
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
        // anchor/base 可能来自 DB 读回（字段按系统时区解释），先按应用
        // 时区重新解释再取时分，避免"应用时区≠系统时区"时整体偏移
        final aa = AppClock.asApp(anchor);
        final bb = AppClock.asApp(base);
        final startDay = AppClock.at(aa.year, aa.month, aa.day);
        final hit = RruleService.instance.nearestHitOnOrNear(startDay, rrule);
        final startDayHit = hit ?? startDay;
        final newStart = AppClock.at(
          startDayHit.year,
          startDayHit.month,
          startDayHit.day,
          bb.hour,
          bb.minute,
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
    DateTime toDate;
    if (t.isAllDay) {
      // 全天任务改期本次维持全天：只改日期，不选时间（粒度与计划时间对齐）
      toDate = AppClock.at(picked.year, picked.month, picked.day);
    } else {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: ps?.hour ?? 9, minute: ps?.minute ?? 0),
        helpText: '选择实例时间',
      );
      if (pickedTime == null || !mounted) return;
      toDate = AppClock.at(
        picked.year,
        picked.month,
        picked.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    }
    final notifier = ref.read(tasksControllerProvider.notifier);
    // 记录例外 ID，撤销时删除该例外（而非新增反向例外）
    final exId = await notifier.editException(t.id, instDay, toDate);
    _load();
    if (mounted) {
      showAppSnackBar(
        context,
        t.isAllDay
            ? '已改期到 ${DateUtilsEx.dateCn(toDate)}'
            : '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
        actionLabel: '撤销',
        onAction: () async {
          await notifier.undoEditException(t.id, exId);
          _load();
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
        content: Text('「${t.title}」及其子任务将移入回收站，可恢复'),
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

class _ListTileRow extends StatelessWidget {
  const _ListTileRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  /// 可选清除动作：非空时在行尾渲染"×"清除按钮（如截止时间清除）
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onClear != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              tooltip: '清除',
              onPressed: onClear,
            ),
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
