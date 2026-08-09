import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/features/calendar/providers.dart';
import 'package:zhuoluo/features/calendar/quick_add_sheets.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

class InstanceActionSheet extends ConsumerStatefulWidget {
  const InstanceActionSheet({super.key, required this.item});

  final CalendarItem item;

  @override
  ConsumerState<InstanceActionSheet> createState() =>
      InstanceActionSheetState();
}

class InstanceActionSheetState extends ConsumerState<InstanceActionSheet> {
  /// 例外改期：实例日 → 改期目标时刻（5.3：弹层字幕显示改期后的时间）
  DateTime? _rescheduledTo;

  CalendarItem get item => widget.item;

  @override
  void initState() {
    super.initState();
    _loadException();
  }

  Future<void> _loadException() async {
    final db = ref.read(dbProvider);
    final exs = await db.getExceptions(item.task.id);
    for (final ex in exs) {
      final od = ex.overrideScheduledDate;
      if (ex.action == 'edit' &&
          od != null &&
          DateUtilsEx.sameDay(od, item.instanceDate)) {
        if (mounted) {
          setState(() => _rescheduledTo = od);
        }
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(calendarControllerProvider.notifier);
    final t = item.task;
    final day = item.instanceDate;
    // 5.3：被例外改期到的实例显示目标时刻（原 planStart 已不再准确）
    final displayTime = _rescheduledTo ?? t.planStart;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${DateUtilsEx.dateCn(day)}'
              '${t.rrule.isNotEmpty ? '（本次实例）' : ''}'
              '${t.isAllDay ? '' : ' · ${DateUtilsEx.timeCn(displayTime ?? day)}'}',
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              item.completed ? Icons.undo : Icons.check_circle_outline,
            ),
            title: Text(item.completed ? '撤销完成本次' : '完成本次'),
            onTap: () {
              Navigator.pop(context);
              notifier.toggleComplete(item);
            },
          ),
          if (t.rrule.isNotEmpty) ...[
            ListTile(
              leading: const Icon(Icons.skip_next),
              title: const Text('跳过本次'),
              onTap: () async {
                // 先等待跳过写入完成，再弹撤销条（此前先弹条后
                // fire-and-forget 执行，快速点撤销读到旧 skippedDates 会静默失效）
                await notifier.skipInstance(t.id, day);
                if (!mounted) return;
                showAppSnackBar(
                  this.context,
                  '已跳过 ${DateUtilsEx.dateCn(day)} 的实例',
                  actionLabel: '撤销',
                  onAction: () => notifier.unskipInstance(t.id, day),
                  icon: Icons.skip_next,
                );
                Navigator.pop(this.context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.event_repeat),
              title: const Text('改期本次'),
              onTap: () => _pickReschedule(ref, item),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('查看详情'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: t.id)),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 改期本次（日期 + 时间；撤销=删除例外恢复原日期）
  Future<void> _pickReschedule(WidgetRef ref, CalendarItem item) async {
    final now = AppClock.now();
    final ps = item.task.planStart;
    // 日视图可翻到百年前，实例日期超界会触发 DatePicker 断言崩溃
    final first = DateTime(now.year - 1);
    final last = DateTime(now.year + 5);
    final initial = item.instanceDate;
    final clamped = initial.isBefore(first)
        ? first
        : (initial.isAfter(last) ? last : initial);
    final picked = await showDatePicker(
      context: context,
      initialDate: clamped,
      firstDate: first,
      lastDate: last,
      helpText: '改期本次到',
    );
    if (picked == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: ps == null ? 9 : AppClock.asApp(ps).hour,
        minute: ps == null ? 0 : AppClock.asApp(ps).minute,
      ),
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
    final tasksNotifier = ref.read(tasksControllerProvider.notifier);
    // 记录例外 ID，撤销时删除该例外（而非新增反向例外）
    final exId = await tasksNotifier.editException(
      item.task.id,
      item.instanceDate,
      toDate,
    );
    if (!mounted) return;
    showAppSnackBar(
      context,
      '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
      actionLabel: '撤销',
      onAction: () {
        tasksNotifier.undoEditException(item.task.id, exId);
      },
      icon: Icons.event_repeat,
    );
  }
}

/// 月视图日期预览层（完整可操作）


class DayPreviewSheet extends ConsumerStatefulWidget {
  const DayPreviewSheet({super.key, required this.day});

  final DateTime day;

  @override
  ConsumerState<DayPreviewSheet> createState() => DayPreviewSheetState();
}

class DayPreviewSheetState extends ConsumerState<DayPreviewSheet> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(calendarControllerProvider);
    final notifier = ref.read(calendarControllerProvider.notifier);
    final dayItems =
        state.items
            .where((i) => DateUtilsEx.sameDay(i.instanceDate, widget.day))
            .toList()
          ..sort((a, b) {
            final at = a.task.planStart;
            final bt = b.task.planStart;
            if (at == null && bt == null) return 0;
            if (at == null) return 1;
            if (bt == null) return -1;
            return at.compareTo(bt);
          });
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                DateUtilsEx.dateCn(widget.day),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (dayItems.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '当天没有任务',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    for (final item in dayItems)
                      ListTile(
                        dense: true,
                        // 完成态：不明显的灰色
                        tileColor: item.completed
                            ? Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest
                            : null,
                        leading: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            item.completed
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: item.completed ? Colors.grey.shade400 : null,
                          ),
                          onPressed: () => notifier.toggleComplete(item),
                        ),
                        title: Text(
                          item.task.title,
                          style: TextStyle(
                            color: item.completed
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : null,
                            decoration: item.completed
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          item.task.isAllDay || item.task.planStart == null
                              ? '全天'
                              : '${DateUtilsEx.timeCn(item.displayTime ?? item.task.planStart!)} · '
                                    '${_listNameOf(context, item.task.listId)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        // B3：重复任务实例可跳过本次/改期
                        trailing: item.task.rrule.isNotEmpty
                            ? PopupMenuButton<String>(
                                onSelected: (v) =>
                                    _handleInstanceAction(item, v),
                                itemBuilder: (c) => const [
                                  PopupMenuItem(
                                    value: 'skip',
                                    child: Text('跳过本次'),
                                  ),
                                  PopupMenuItem(
                                    value: 'reschedule',
                                    child: Text('改期'),
                                  ),
                                ],
                              )
                            : null,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  TaskDetailPage(taskId: item.task.id),
                            ),
                          );
                        },
                      ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加任务'),
              onTap: () {
                Navigator.pop(context);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (c) => QuickAddSheetWithDefaults(widget.day),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// B3：重复任务实例操作（跳过本次 / 改期到其他日期）
  Future<void> _handleInstanceAction(CalendarItem item, String action) async {
    final notifier = ref.read(calendarControllerProvider.notifier);
    if (action == 'skip') {
      await notifier.skipInstance(item.task.id, item.instanceDate);
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已跳过 ${DateUtilsEx.dateCn(item.instanceDate)} 的实例',
        actionLabel: '撤销',
        onAction: () =>
            notifier.unskipInstance(item.task.id, item.instanceDate),
        icon: Icons.skip_next,
      );
      return;
    }
    if (action == 'reschedule') {
      final now = AppClock.now();
      final ps = item.task.planStart;
      // 月视图可翻到很久以前，实例日期超界会触发 DatePicker 断言崩溃；
      // 范围前后各 60 年（覆盖日常改期，超界时钳制到边界）
      final first = DateTime(now.year - 60);
      final last = DateTime(now.year + 60);
      final initial = item.instanceDate;
      final clamped = initial.isBefore(first)
          ? first
          : (initial.isAfter(last) ? last : initial);
      final picked = await showDatePicker(
        context: context,
        initialDate: clamped,
        firstDate: first,
        lastDate: last,
        helpText: '改期到',
      );
      if (picked == null || !mounted) return;
      // 与弹层入口一致——改期保留/选择时分（此前只选日期丢时分，
      // 且更新既有例外时会覆盖之前带时分的改期）
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
          hour: ps == null ? 9 : AppClock.asApp(ps).hour,
          minute: ps == null ? 0 : AppClock.asApp(ps).minute,
        ),
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
      // 经任务控制器写入例外，并触发数据版本刷新（日历自动重载）
      final tasksNotifier = ref.read(tasksControllerProvider.notifier);
      final exId = await tasksNotifier.editException(
        item.task.id,
        item.instanceDate,
        toDate,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        '已改期到 ${DateUtilsEx.dateCn(toDate)} ${DateUtilsEx.timeCn(toDate)}',
        actionLabel: '撤销',
        onAction: () => tasksNotifier.undoEditException(item.task.id, exId),
        icon: Icons.event_repeat,
      );
    }
  }

  String _listNameOf(BuildContext context, int listId) {
    final lists = ref.read(tasksControllerProvider).lists;
    final l = lists.where((e) => e.id == listId).firstOrNull;
    return l?.name ?? '';
  }
}

