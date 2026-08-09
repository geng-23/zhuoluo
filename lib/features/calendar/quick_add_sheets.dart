import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/core/utils/task_title.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';
import 'package:zhuoluo/features/task/providers.dart';
import 'package:zhuoluo/features/task/task_detail_page.dart';

/// C6-2：日历添加固定进收件箱（此前静默进入任务页当前选中的清单）。
/// 偏好设置组：设置了默认清单时优先用默认清单，否则回落收件箱。
Future<int> _defaultListId(WidgetRef ref) async {
  final db = ref.read(dbProvider);
  final preferred = await ref.read(settingsProvider).getDefaultListId();
  if (preferred != null) return preferred;
  final list = await db.getDefaultList();
  return list.id;
}

/// 日历快速添加（带起止时间）与默认日期快速添加。
/// P3：从 calendar_page 抽离——此前 views.dart ↔ calendar_page.dart 循环 import。

/// 拖动选时区间创建（预填 planStart/planEnd）
class QuickAddSheetWithRange extends ConsumerStatefulWidget {
  const QuickAddSheetWithRange({
    super.key,
    required this.start,
    required this.end,
  });

  final DateTime start;
  final DateTime end;

  @override
  ConsumerState<QuickAddSheetWithRange> createState() =>
      _QuickAddSheetWithRangeState();
}

class _QuickAddSheetWithRangeState
    extends ConsumerState<QuickAddSheetWithRange> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).viewInsets.bottom;
    final s = widget.start;
    final e = widget.end;
    return Padding(
      padding: EdgeInsets.only(bottom: padding),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '计划时间 ${DateUtilsEx.dateCn(s)} '
                '${DateUtilsEx.timeCn(s)}-${DateUtilsEx.timeCn(e)}'
                '${DateUtilsEx.sameDay(s, e) ? '' : '（${DateUtilsEx.dateCn(e)}）'}',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: '输入任务标题',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.newline,
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

  Future<void> _submit() async {
    final text = _controller.text.trim();
    // C4-4：空文本统一提示（此前区间快建会凭空创建"未命名"任务）
    if (text.isEmpty) {
      showAppSnackBar(
        context,
        '请输入任务内容',
        icon: Icons.info_outline,
      );
      return;
    }
    final title = extractTaskTitle(text);
    // await + mounted 守卫——此前 .then 回调在 pop/dispose 之后
    // 使用 ref，会抛 "Cannot use ref after dispose"，任务偶发未创建
    final defId = await _defaultListId(ref);
    if (!mounted) return;
    await ref
        .read(tasksControllerProvider.notifier)
        .addTask(
          title: title,
          listId: defId,
          planStart: widget.start,
          planEnd: widget.end,
        );
    if (!mounted) return;
    _controller.clear();
    Navigator.pop(context);
  }

  /// 快速创建后展开详情页继续编辑（C4：空标题也创建"未命名"进入详情）
  Future<void> _submitAndOpenDetail() async {
    final text = _controller.text.trim();
    final title = text.isEmpty ? '未命名' : extractTaskTitle(text);
    final defId = await _defaultListId(ref);
    final id = await ref
        .read(tasksControllerProvider.notifier)
        .addTask(
          title: title,
          listId: defId,
          planStart: widget.start,
          planEnd: widget.end,
        );
    _controller.clear();
    if (!mounted) return;
    Navigator.pop(context);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: id)));
  }
}

/// 快速添加（日历默认预填今天+默认时间）
/// C6-1：可传入 [start]/[end] 预填计划时段（时间轴点空白位置）
class QuickAddSheetWithDefaults extends ConsumerStatefulWidget {
  const QuickAddSheetWithDefaults(
    this.defaultDate, {
    super.key,
    this.start,
    this.end,
  });

  final DateTime defaultDate;
  final DateTime? start;
  final DateTime? end;

  @override
  ConsumerState<QuickAddSheetWithDefaults> createState() =>
      _QuickAddSheetWithDefaultsState();
}

class _QuickAddSheetWithDefaultsState
    extends ConsumerState<QuickAddSheetWithDefaults> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: padding),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                // C6-1：有预填时段时显示计划时间（点击位置表达的意图）
                widget.start == null
                    ? '添加到 ${DateUtilsEx.dateCn(widget.defaultDate)}'
                    : '添加到 ${DateUtilsEx.dateCn(widget.start!)} '
                          '${DateUtilsEx.timeCn(widget.start!)}-'
                          '${DateUtilsEx.timeCn(widget.end ?? widget.start!.add(const Duration(hours: 1)))}',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: '输入任务，如：下午3点交报告',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.newline,
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

  (DateTime?, DateTime?, bool) _parsePlan(String text) {
    final parsed = ChineseDateParser.instance.parse(text);
    // C6-1：未解析出日期/时间且有预填时段 → 用预填的定时计划
    if (parsed.time == null &&
        parsed.date == null &&
        widget.start != null) {
      final s = widget.start!;
      return (s, widget.end ?? s.add(const Duration(hours: 1)), false);
    }
    final date = parsed.date ?? widget.defaultDate;
    var isAllDay = true;
    DateTime? ps;
    DateTime? pe;
    if (parsed.time != null) {
      isAllDay = false;
      ps = DateTime(
        date.year,
        date.month,
        date.day,
        parsed.time!.hour,
        parsed.time!.minute,
      );
      if (parsed.endTime != null) {
        var eh = parsed.endTime!.hour;
        final em = parsed.endTime!.minute;
        pe = eh < parsed.time!.hour
            ? DateTime(date.year, date.month, date.day + 1, eh, em)
            : DateTime(date.year, date.month, date.day, eh, em);
      } else {
        pe = ps.add(const Duration(hours: 1));
      }
    } else {
      ps = DateTime(date.year, date.month, date.day);
      pe = DateTime(date.year, date.month, date.day + 1);
    }
    // C3-1：重复+无明确时间 → 保持全天（此前强改 isAllDay=false，
    // 生成 00:00-00:00 的"定时跨天"任务，与任务页入口行为不一致）
    return (ps, pe, isAllDay);
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    // C4-4：空文本统一提示（与任务页/区间快建一致）
    if (text.isEmpty) {
      showAppSnackBar(
        context,
        '请输入任务内容',
        icon: Icons.info_outline,
      );
      return;
    }
    final (ps, pe, isAllDay) = _parsePlan(text);
    // C6-2：固定进收件箱（不随任务页当前清单）
    // await + mounted 守卫——此前 .then 回调在 pop/dispose 之后
    // 使用 ref，会抛 "Cannot use ref after dispose"，任务偶发未创建
    final defId = await _defaultListId(ref);
    if (!mounted) return;
    await ref
        .read(tasksControllerProvider.notifier)
        .addTask(
          title: extractTaskTitle(text),
          listId: defId,
          planStart: ps,
          planEnd: pe,
          isAllDay: isAllDay,
          rrule: ChineseDateParser.instance.parse(text).rrule,
        );
    if (!mounted) return;
    _controller.clear();
    Navigator.pop(context);
  }

  /// 快速创建后展开详情页继续编辑（C4：空标题也创建"未命名"进入详情）
  Future<void> _submitAndOpenDetail() async {
    final text = _controller.text.trim();
    final parsed = ChineseDateParser.instance.parse(text);
    final (ps, pe, isAllDay) = _parsePlan(text);
    final defId = await _defaultListId(ref);
    final id = await ref
        .read(tasksControllerProvider.notifier)
        .addTask(
          title: text.isEmpty ? '未命名' : extractTaskTitle(text),
          listId: defId,
          planStart: ps,
          planEnd: pe,
          isAllDay: isAllDay,
          rrule: parsed.rrule,
        );
    _controller.clear();
    if (!mounted) return;
    Navigator.pop(context);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: id)));
  }
}
