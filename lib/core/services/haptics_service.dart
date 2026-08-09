import 'package:flutter/services.dart';

/// 触觉反馈（震动），全局可关闭（设置页开关，启动时从数据库加载）
class Haptics {
  Haptics._();

  /// 测试环境关闭（widget 测试无平台通道）
  static bool enabled = true;

  /// 震动总开关（设置页可关）
  static bool hapticsEnabled = true;

  static Future<void> light() async {
    if (!enabled || !hapticsEnabled) return;
    try {
      await HapticFeedback.lightImpact();
    } catch (_) {
      // 平台不支持时静默
    }
  }

  static Future<void> medium() async {
    if (!enabled || !hapticsEnabled) return;
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  static Future<void> select() async {
    if (!enabled || !hapticsEnabled) return;
    try {
      await HapticFeedback.selectionClick();
    } catch (_) {}
  }
}
