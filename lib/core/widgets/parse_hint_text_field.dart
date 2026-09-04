import 'package:flutter/material.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';

/// 快建输入框：解析器未命中时间但输入含疑似时间词时，在 helperText
/// 显示轻提示（如「每周八」「下周交」这类未覆盖句式此前静默丢失）。
/// 已命中或无疑似词时不显示，不打扰正常输入。
class ParseHintTextField extends StatefulWidget {
  const ParseHintTextField({
    super.key,
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  State<ParseHintTextField> createState() => _ParseHintTextFieldState();
}

class _ParseHintTextFieldState extends State<ParseHintTextField> {
  String _hint = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateHint);
    _updateHint();
  }

  @override
  void didUpdateWidget(ParseHintTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateHint);
      widget.controller.addListener(_updateHint);
      _updateHint();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateHint);
    super.dispose();
  }

  void _updateHint() {
    final text = widget.controller.text.trim();
    final parsed = ChineseDateParser.instance.parse(text);
    final hint = ChineseDateParser.unmatchedTimeHint(text, parsed) ?? '';
    if (hint != _hint && mounted) {
      setState(() => _hint = hint);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      autofocus: true,
      maxLines: 3,
      minLines: 1,
      decoration: InputDecoration(
        hintText: widget.hintText,
        helperText: _hint.isEmpty ? null : _hint,
        helperStyle: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.tertiary,
        ),
        border: const OutlineInputBorder(),
      ),
      textInputAction: TextInputAction.newline,
    );
  }
}
