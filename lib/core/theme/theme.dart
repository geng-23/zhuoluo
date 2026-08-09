import 'package:flutter/material.dart';

/// 着落主题
class AppTheme {
  AppTheme._();

  static const seedColor = Color(0xFF4F8EF7);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: seedColor);
    return _build(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    return _build(scheme);
  }

  /// B1：组件级主题定制——统一卡片/列表/提示条/导航栏/输入框的
  /// 圆角、间距与表面色，收敛各页面手写样式
  static ThemeData _build(ColorScheme s) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: s,
      scaffoldBackgroundColor: s.surface,
      cardTheme: CardThemeData(
        elevation: 1,
        clipBehavior: Clip.antiAlias,
        color: s.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: AppRadius.tile),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 2,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: s.inverseSurface,
        contentTextStyle: TextStyle(
          color: s.onInverseSurface,
          fontSize: AppTextSizes.body,
        ),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.snackbar),
        actionTextColor: s.primary,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        // A13：输入框带填充（暗色下无填充的裸边框刺眼）；
        // 填充色用主题表面容器色，深浅主题自适应
        filled: true,
        fillColor: s.surfaceContainerHighest,
        border: OutlineInputBorder(borderRadius: AppRadius.field),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.field,
          borderSide: BorderSide(color: s.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.field,
          borderSide: BorderSide(color: s.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
      ),
    );
  }
}

/// 统一圆角 Token
class AppRadius {
  AppRadius._();

  static final card = BorderRadius.circular(16);
  static final tile = BorderRadius.circular(12);
  static final snackbar = BorderRadius.circular(12);
  static final field = BorderRadius.circular(12);
}

/// 统一间距 Token（4dp 基准）
class AppSpacing {
  AppSpacing._();

  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
}

/// 统一字号 Token
class AppTextSizes {
  AppTextSizes._();

  static const body = 14.0;
}

/// 清单颜色解析（十六进制 → Color）
Color colorFromHex(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16) ?? 0xFF4F8EF7;
  return Color(v);
}

/// 象限颜色（设计文档 §4.3）
const quadrantColors = [
  Color(0xFFE53935), // Q1 重要且紧急（红）
  Color(0xFFFDD835), // Q2 重要不紧急（黄）
  Color(0xFF1E88E5), // Q3 紧急不重要（蓝）
  Color(0xFFBDBDBD), // Q4 都不（灰）——截图⑤：提亮提升暗色下可读性
];

const quadrantNames = ['重要紧急', '重要不紧急', '紧急不重要', '一般'];
