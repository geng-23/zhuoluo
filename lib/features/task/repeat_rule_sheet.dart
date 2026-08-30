import 'package:flutter/material.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';
import 'package:zhuoluo/core/utils/app_snackbar.dart';
import 'package:zhuoluo/core/utils/date_utils.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';


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
    // 键盘避让（viewInsets 动画内边距）+ 可滚动 + 最大高度限制，
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
                    Icon(
                      Icons.event,
                      size: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
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