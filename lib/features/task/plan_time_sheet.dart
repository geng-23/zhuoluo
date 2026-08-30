import 'package:flutter/material.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';


/// 计划时间表单（开始时间可留空=全天；结束时间可留空=开始+1h；
/// 底部"清除计划时间"返回 start=null 表示清除整个计划）
class PlanTimeSheet extends StatefulWidget {
  const PlanTimeSheet({
    super.key,
    required this.initialStart,
    required this.initialEnd,
    required this.initialAllDay,
  });

  final DateTime? initialStart;
  final DateTime? initialEnd;
  final bool initialAllDay;

  @override
  State<PlanTimeSheet> createState() => _PlanTimeSheetState();
}

class _PlanTimeSheetState extends State<PlanTimeSheet> {
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
                        color: _endDate == null
                            ? Theme.of(context).colorScheme.outline
                            : null,
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
                        style: TextStyle(color: Theme.of(context).colorScheme.outline),
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
              children: [
                // 清除整个计划时间（start=null）；开始日期必填的旧语义无法清除
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, (null, null, false)),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('清除计划时间'),
                ),
                const Spacer(),
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