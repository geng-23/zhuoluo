import 'package:flutter/material.dart';

/// 着落主题
class AppTheme {
  AppTheme._();

  /// 默认种子色（蓝）
  static const seedColor = Color(0xFF4F8EF7);

  static ThemeData light(Color seed) {
    final scheme = ColorScheme.fromSeed(seedColor: seed);
    return _build(scheme);
  }

  static ThemeData dark(Color seed) {
    var scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    // 暗色微调：surfaceContainerLow 提亮一档，避免卡片与背景粘连
    scheme = scheme.copyWith(
      surfaceContainerLow: Color.lerp(
        scheme.surfaceContainerLow,
        scheme.surfaceContainerHigh,
        0.18,
      ),
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
      // 各页面统一的平面 AppBar：滚动时不再叠加 M3 默认的
      // surfaceTint 灰带（浅色内容上显脏、与任务页白色观感不一致）
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: s.surface,
      ),
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
          borderRadius: AppRadius.pill,
        ),
        indicatorColor: s.secondaryContainer,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? s.onSecondaryContainer
                : s.onSurfaceVariant,
            size: states.contains(WidgetState.selected) ? 26 : 24,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? s.onSurface
                : s.onSurfaceVariant,
          ),
        ),
      ),
      // 所有模态底部弹层统一带拖拽把手（此前全仓库 0 处 showDragHandle，
      // 无下滑关闭提示）；形状/背景走 M3 默认
      bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
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
      // ===== 主题组件补全（2026-08-29）=====
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: s.primary,
        foregroundColor: s.onPrimary,
        elevation: 4,
        focusElevation: 6,
        hoverElevation: 6,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
      ),
      dividerTheme: DividerThemeData(
        color: s.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: s.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: s.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.tile),
        textStyle: TextStyle(fontSize: AppTextSizes.body, color: s.onSurface),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: AppRadius.tile),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? s.primary : null,
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? s.primary : null,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.tile),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontSize: AppTextSizes.bodySm,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: AppRadius.tile),
        side: BorderSide(color: s.outlineVariant),
        labelStyle: TextStyle(fontSize: AppTextSizes.bodySm),
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
  static final pill = BorderRadius.circular(999);
}

/// 统一间距 Token（4dp 基准）
class AppSpacing {
  AppSpacing._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
}

/// 统一字号 Token
class AppTextSizes {
  AppTextSizes._();

  static const caption = 12.0;
  static const bodySm = 13.0;
  static const body = 14.0;
  static const title = 16.0;
  static const display = 32.0;
}

/// 语义文本样式（替代全库散落的 fontsize+greyshade 硬编码）
class AppTextStyles {
  AppTextStyles._();

  /// 列表副标题（12/onSurfaceVariant）
  static TextStyle subtitle(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return TextStyle(fontSize: AppTextSizes.caption, color: s.onSurfaceVariant);
  }

  /// 次要说明（12/outline）
  static TextStyle hint(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return TextStyle(fontSize: AppTextSizes.caption, color: s.outline);
  }

  /// 分组小节标题（13/w600/primary）
  static TextStyle sectionHeader(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return TextStyle(
      fontSize: AppTextSizes.bodySm,
      fontWeight: FontWeight.w600,
      color: s.primary,
    );
  }
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

/// 主题色板（预设 12 色 + 默认蓝）
class ThemePalette {
  ThemePalette._();

  /// 名称（UI 展示用）→ 种子色；首项为默认蓝
  static const colors = <String, Color>{
    '默认蓝': Color(0xFF4F8EF7),
    '紫罗兰': Color(0xFF8E4F8C),
    '玫红': Color(0xFFC2185B),
    '珊瑚红': Color(0xFFE53935),
    '活力橙': Color(0xFFFB8C00),
    '森林绿': Color(0xFF2E7D32),
    '青碧': Color(0xFF00897B),
    '湖畔蓝': Color(0xFF0277BD),
    '藏青': Color(0xFF303F9F),
    '烟灰': Color(0xFF616161),
    '暖棕': Color(0xFF6D4C41),
    '橄榄绿': Color(0xFF827717),
    '石板': Color(0xFF546E7A),
  };

  /// 按 hex 字符串取色；未知/空回退默认蓝
  static Color fromHex(String? hex) => colorFromHex(hex ?? '');

  /// 主题色设置 key 的存储格式（hex 或空 = 默认蓝）
  static String toStore(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
}
