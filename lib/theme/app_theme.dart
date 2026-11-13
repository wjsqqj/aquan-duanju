import 'package:flutter/material.dart';

import '../store/stores.dart';
import 'app_color.dart';
import 'app_metrics.dart';
import 'app_tokens.dart';

/// M3 主题：深浅两套，强调色统一暖橙（短剧内容的观感）。
///
/// 全部取值来自 `lib/theme/` 的 Token（design.md §3）；本文件不写样式字面量，
/// 唯一例外是兼容既有调用点的 [seed]（`mine_screen` 的「关于」里会展示它）。
class AppTheme {
  /// 品牌主色。§4.1 规定它必须与 `AppColors.brand` 同值且不得改动。
  static const seed = Color(0xFFFF7A45);

  static ThemeData light() => _build(AppTokens.subtle, Brightness.light);

  static ThemeData dark() => _build(AppTokens.elevated, Brightness.dark);

  static ThemeData _build(AppTokens tokens, Brightness brightness) {
    final AppColors colors = tokens.colors;
    final AppMetrics metrics = tokens.metrics;
    // 按钮四态底色由 `backgroundColor` 承担，M3 默认叠色一律关掉，保证 hover /
    // pressed 精确等于 Token 值。透明色由 alpha=0 派生，不写色值字面量。
    final Color noOverlay = colors.onBrand.withValues(alpha: 0);

    // 语义色 → M3 角色。不用 `ColorScheme.fromSeed`：它会把暖橙调成 M3 的
    // 粉紫色相，与设计取值对不上（§1.2「语义优先于色相」）。
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: colors.brand,
      onPrimary: colors.onBrand,
      primaryContainer: colors.surface2,
      onPrimaryContainer: colors.brand,
      secondary: colors.brandHover,
      onSecondary: colors.onBrand,
      secondaryContainer: colors.surface2,
      onSecondaryContainer: colors.brand,
      tertiary: colors.info,
      onTertiary: colors.onBrand,
      tertiaryContainer: colors.surface2,
      onTertiaryContainer: colors.info,
      error: colors.danger,
      onError: colors.onBrand,
      errorContainer: colors.surface2,
      onErrorContainer: colors.danger,
      surface: colors.canvas,
      onSurface: colors.textPrimary,
      surfaceDim: colors.canvas,
      surfaceBright: colors.surface3,
      surfaceContainerLowest: colors.surface1,
      surfaceContainerLow: colors.surface1,
      surfaceContainer: colors.surface2,
      surfaceContainerHigh: colors.surface3,
      surfaceContainerHighest: colors.surface3,
      onSurfaceVariant: colors.textSecondary,
      // `outline` 在本项目里被大量既有代码当「淡文字」用（未选中 tab、卡片
      // 副标题等），所以它必须是可读的中性色；分隔线走 `outlineVariant`。
      outline: colors.outline,
      outlineVariant: colors.hairline,
      inverseSurface: colors.textPrimary,
      onInverseSurface: colors.canvas,
      inversePrimary: colors.brand,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: tokens.textTheme,
      // AC1.4：深浅两套都显式赋值（旧实现只在浅色下给值）。
      scaffoldBackgroundColor: colors.canvas,
      canvasColor: colors.canvas,
      dividerColor: colors.hairline,
      iconTheme: IconThemeData(color: colors.textSecondary),
      extensions: <ThemeExtension<dynamic>>[tokens],
      appBarTheme: AppBarThemeData(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colors.canvas,
        foregroundColor: colors.textPrimary,
        surfaceTintColor: colors.canvas,
        titleTextStyle: tokens.h2,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surface1,
        surfaceTintColor: colors.surface1,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.radiusMd),
          side: BorderSide(color: colors.hairline, width: metrics.hairline),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.hairline,
        thickness: metrics.hairline,
        space: metrics.hairline,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.disabled)) return colors.surface2;
            if (states.contains(WidgetState.pressed)) {
              return colors.brandPressed;
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return colors.brandHover;
            }
            return colors.brand;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.disabled)
                ? colors.textTertiary
                : colors.onBrand,
          ),
          overlayColor: WidgetStatePropertyAll<Color>(noOverlay),
          elevation: const WidgetStatePropertyAll<double>(0),
          textStyle: WidgetStatePropertyAll<TextStyle>(tokens.bodyStrong),
          padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(
              horizontal: metrics.s20,
              vertical: metrics.s12,
            ),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(metrics.radiusSm),
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.disabled)
                ? colors.textTertiary
                : colors.brand,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)
                ? colors.surface2
                : noOverlay,
          ),
          side: WidgetStateProperty.resolveWith<BorderSide>(
            (states) => BorderSide(
              color: states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                  ? colors.brand
                  : colors.hairline,
              width: metrics.hairline,
            ),
          ),
          elevation: const WidgetStatePropertyAll<double>(0),
          textStyle: WidgetStatePropertyAll<TextStyle>(tokens.bodyStrong),
          padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(
              horizontal: metrics.s20,
              vertical: metrics.s12,
            ),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(metrics.radiusSm),
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.disabled)
                ? colors.textTertiary
                : colors.brand,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.hovered)
                ? colors.surface2
                : noOverlay,
          ),
          elevation: const WidgetStatePropertyAll<double>(0),
          textStyle: WidgetStatePropertyAll<TextStyle>(tokens.bodyStrong),
          padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(
              horizontal: metrics.s12,
              vertical: metrics.s8,
            ),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(metrics.radiusSm),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: colors.surface2,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: metrics.s12,
          vertical: metrics.s12,
        ),
        // 占位符 / 前后缀图标也走 `outline`（4.55:1）：`textTertiary` 只有
        // 约 2.9:1，作为输入框占位与图标偏低。
        hintStyle: tokens.body.copyWith(color: colors.outline),
        labelStyle: tokens.body.copyWith(color: colors.textSecondary),
        floatingLabelStyle: tokens.label.copyWith(color: colors.brand),
        helperStyle: tokens.caption.copyWith(color: colors.outline),
        errorStyle: tokens.caption.copyWith(color: colors.danger),
        prefixIconColor: colors.outline,
        suffixIconColor: colors.outline,
        border: _fieldBorder(colors.hairline, metrics),
        enabledBorder: _fieldBorder(colors.hairline, metrics),
        disabledBorder: _fieldBorder(colors.hairline, metrics),
        focusedBorder: _fieldBorder(
          colors.focusRing,
          metrics,
          width: metrics.focusRing,
        ),
        errorBorder: _fieldBorder(colors.danger, metrics),
        focusedErrorBorder: _fieldBorder(
          colors.danger,
          metrics,
          width: metrics.focusRing,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surface2,
        selectedColor: colors.brand,
        disabledColor: colors.surface2,
        secondarySelectedColor: colors.brand,
        checkmarkColor: colors.onBrand,
        showCheckmark: false,
        elevation: 0,
        pressElevation: 0,
        labelStyle: tokens.label.copyWith(color: colors.textSecondary),
        secondaryLabelStyle: tokens.label.copyWith(color: colors.onBrand),
        padding: EdgeInsets.symmetric(
          horizontal: metrics.s8,
          vertical: metrics.s4,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.radiusSm),
          side: BorderSide(color: colors.hairline, width: metrics.hairline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface3,
        surfaceTintColor: colors.surface3,
        elevation: 0,
        titleTextStyle: tokens.h2,
        contentTextStyle: tokens.body.copyWith(color: colors.textSecondary),
        insetPadding: EdgeInsets.symmetric(
          horizontal: metrics.s24,
          vertical: metrics.s24,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.radiusLg),
          side: BorderSide(color: colors.hairline, width: metrics.hairline),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface3,
        modalBackgroundColor: colors.surface3,
        surfaceTintColor: colors.surface3,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: false,
        dragHandleColor: colors.hairline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(metrics.radiusLg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.surface3,
        contentTextStyle: tokens.body.copyWith(color: colors.textPrimary),
        actionTextColor: colors.brand,
        elevation: 0,
        insetPadding: EdgeInsets.all(metrics.s16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.radiusSm),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors.canvas,
        elevation: 0,
        labelType: NavigationRailLabelType.all,
        useIndicator: true,
        indicatorColor: colors.surface2,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.radiusSm),
        ),
        selectedIconTheme: IconThemeData(color: colors.brand),
        unselectedIconTheme: IconThemeData(color: colors.textSecondary),
        selectedLabelTextStyle: tokens.label.copyWith(
          color: colors.brand,
        ),
        unselectedLabelTextStyle: tokens.label.copyWith(
          color: colors.textSecondary,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: metrics.s64,
        elevation: 0,
        backgroundColor: colors.canvas,
        surfaceTintColor: colors.canvas,
        // 底部 Tab 选中指示（批次④ 凝胶化第一步）：胶囊形 + 品牌凝胶底。
        // 果冻物理按压后续若要上，需要自绘 NavigationBar 替身——先以
        // 「凝胶观感」达成（brand 色块 + pill 圆角），不动外壳结构。
        indicatorColor: colors.brand.withValues(alpha: 0.22),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.radiusPill),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.brand
                : colors.textSecondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (states) => tokens.label.copyWith(
            color: states.contains(WidgetState.selected)
                ? colors.brand
                : colors.textSecondary,
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.surface3,
          borderRadius: BorderRadius.circular(metrics.radiusXs),
          border: Border.all(color: colors.hairline, width: metrics.hairline),
        ),
        textStyle: tokens.caption.copyWith(color: colors.textPrimary),
        textAlign: TextAlign.center,
      ),
      // 全局滚动条只定义取色与圆角；粗细由具体组件决定（横向条 3px 是
      // `HorizontalScrollStrip` 的自有契约，见 component-guidelines）。
      scrollbarTheme: ScrollbarThemeData(
        radius: Radius.circular(metrics.radiusXs),
        crossAxisMargin: metrics.s2,
        thumbColor: WidgetStatePropertyAll<Color>(colors.textTertiary),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// 输入框描边：圆角 `radiusSm`，线宽默认 hairline，焦点态用 `focusRing`。
  static OutlineInputBorder _fieldBorder(
    Color color,
    AppMetrics metrics, {
    double? width,
  }) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(metrics.radiusSm),
    borderSide: BorderSide(color: color, width: width ?? metrics.hairline),
  );

  static ThemeMode modeOf(SettingsStore s) {
    switch (s.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
