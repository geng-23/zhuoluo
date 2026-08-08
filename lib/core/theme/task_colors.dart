import 'package:flutter/material.dart';

/// 任务颜色方案（v0.2）
///
/// 亮色模式：浅色背景（黑字可读）
/// 暗色模式：深色背景（白字可读）
/// 色键 c1-c10，空串表示未设置（回退清单色）
class TaskColors {
  TaskColors._();

  static const keys = [
    'c1',
    'c2',
    'c3',
    'c4',
    'c5',
    'c6',
    'c7',
    'c8',
    'c9',
    'c10',
  ];

  /// 亮色模式 10 色（黑字对比度充足）
  static const light = {
    'c1': Color(0xFFFFCDD2), // 浅红
    'c2': Color(0xFFFFE0B2), // 浅橙
    'c3': Color(0xFFFFF9C4), // 浅黄
    'c4': Color(0xFFC8E6C9), // 浅绿
    'c5': Color(0xFFB2DFDB), // 浅青
    'c6': Color(0xFFB3E5FC), // 浅蓝
    'c7': Color(0xFFBBDEFB), // 浅蓝灰
    'c8': Color(0xFFD1C4E9), // 浅紫
    'c9': Color(0xFFF8BBD0), // 浅粉
    'c10': Color(0xFFE0E0E0), // 浅灰
  };

  /// 暗色模式 10 色（白字对比度充足）
  static const dark = {
    'c1': Color(0xFFB71C1C), // 深红
    'c2': Color(0xFFE65100), // 深橙
    'c3': Color(0xFFF9A825), // 深黄
    'c4': Color(0xFF1B5E20), // 深绿
    'c5': Color(0xFF00695C), // 深青
    'c6': Color(0xFF01579B), // 深蓝
    'c7': Color(0xFF283593), // 深蓝紫
    'c8': Color(0xFF4A148C), // 深紫
    'c9': Color(0xFF880E4F), // 深粉
    'c10': Color(0xFF424242), // 深灰
  };

  /// 按主题取任务颜色；未设置返回 null
  static Color? colorOf(String? key, Brightness brightness) {
    if (key == null || key.isEmpty) return null;
    final map = brightness == Brightness.dark ? dark : light;
    return map[key];
  }

  /// 按主题取任务颜色的强调色（用于左侧竖线/文字，自动黑白）
  /// B2：按 WCAG 相对亮度对比度选择（阈值 4.5:1），替代 0.5 二值判断——
  /// 中间亮度色（深黄/深橙）此前对比度不足
  static Color textOn(Color bg) {
    final lum = bg.computeLuminance();
    // 白字对比度 = 1.05 / (lum + 0.05)；黑字 = (lum + 0.05) / 0.05
    final whiteContrast = 1.05 / (lum + 0.05);
    return whiteContrast >= 4.5 ? Colors.white : Colors.black87;
  }
}
