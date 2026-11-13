import 'package:flutter/material.dart';

import 'app_color.dart';
import 'app_metrics.dart';
import 'app_typography.dart';

/// 设计 Token 聚合（design.md §3 L2/L3 + §6 数据流）。
///
/// 访问方式：`context.app`（见 [AppTokensX]）→ `colors` / `textTheme` / `metrics`。
///
/// **兜底**：裸 `MaterialApp`（没有注册本扩展）时 `context.app` 返回
/// [AppTokens.subtle] / [AppTokens.elevated] 静态实例，绝不抛异常（§7.4）。
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.colors,
    required this.textTheme,
    required this.metrics,
  });

  /// L2 语义色。
  final AppColors colors;

  /// 10 级字阶铺满的 M3 [TextTheme]。
  final TextTheme textTheme;

  /// 间距 / 圆角 / 描边 / 动效 / 光晕。
  final AppMetrics metrics;

  /// 浅色兜底实例（§6 命名为 `subtle`）。
  static final AppTokens subtle = AppTokens(
    colors: AppColors.light(),
    textTheme: AppTypography.textTheme(AppColors.light()),
    metrics: AppMetrics.standard,
  );

  /// 深色兜底实例（§6 命名为 `elevated`）。
  static final AppTokens elevated = AppTokens(
    colors: AppColors.dark(),
    textTheme: AppTypography.textTheme(AppColors.dark()),
    metrics: AppMetrics.standard,
  );

  /// 按亮度取兜底实例（缺扩展时用）。
  static AppTokens fallbackFor(Brightness brightness) =>
      brightness == Brightness.dark ? elevated : subtle;

  // ---------------------------------------------------------------------------
  // 10 级字阶具名访问（槽位映射与 `AppTypography.textTheme` 的表格一致）
  // ---------------------------------------------------------------------------

  /// 30 / 700 —— 首页头图标题。
  TextStyle get display => textTheme.displaySmall!;

  /// 24 / 600 —— 详情页剧名。
  TextStyle get h1 => textTheme.headlineMedium!;

  /// 20 / 600 —— 分区大标题。
  TextStyle get h2 => textTheme.headlineSmall!;

  /// 17 / 600 —— 卡片组标题。
  TextStyle get h3 => textTheme.titleLarge!;

  /// 15 / 600 —— 卡片标题 / 列表主行。
  TextStyle get title => textTheme.titleMedium!;

  /// 14 / 400 —— 正文。
  TextStyle get body => textTheme.bodyMedium!;

  /// 14 / 600 —— 强调正文 / 按钮文字。
  TextStyle get bodyStrong => textTheme.bodyLarge!;

  /// 13 / 500 —— 次要信息 / 元数据。
  TextStyle get label => textTheme.labelMedium!;

  /// 12 / 400 —— 说明 / 辅助。
  TextStyle get caption => textTheme.bodySmall!;

  /// 11 / 600 —— 大写小标签。
  TextStyle get micro => textTheme.labelSmall!;

  /// 数字专用（等宽 `tnum`）：集数 / 时长 / 评分 / 名次 / 百分比。
  TextStyle get numbers =>
      AppTypography.numbers.copyWith(color: colors.textSecondary);

  @override
  AppTokens copyWith({
    AppColors? colors,
    TextTheme? textTheme,
    AppMetrics? metrics,
  }) => AppTokens(
    colors: colors ?? this.colors,
    textTheme: textTheme ?? this.textTheme,
    metrics: metrics ?? this.metrics,
  );

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    if (t <= 0) return this;
    if (t >= 1) return other;
    return AppTokens(
      colors: colors.lerpFrom(other.colors, t),
      textTheme: TextTheme.lerp(textTheme, other.textTheme, t),
      metrics: metrics.lerpFrom(other.metrics, t),
    );
  }
}

/// 取设计 Token 的入口：`context.app.colors.brand`。
extension AppTokensX on BuildContext {
  /// 主题里注册了 [AppTokens] 就用它，否则按当前亮度回落静态默认实例。
  AppTokens get app {
    final theme = Theme.of(this);
    return theme.extension<AppTokens>() ??
        AppTokens.fallbackFor(theme.brightness);
  }
}
