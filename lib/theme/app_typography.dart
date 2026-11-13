import 'package:flutter/material.dart';

import 'app_color.dart';

/// 字阶与字体族（design.md §4.4）。
///
/// - 10 级字阶以常量暴露（[display] / [h1] / … / [micro]），供无 `BuildContext`
///   的场景直接使用；常量本身**不带颜色**，颜色由 [textTheme] 或调用方注入。
/// - 需要随主题（深/浅）走时用 [textTheme]：它把 10 级字阶铺满 M3 `TextTheme`
///   的 15 个槽位，避免未填槽位回落到非 Inter 的默认字体。
/// - 阅读器正文不使用这套字阶（D7：`reader_typography.dart` 自治）。
class AppTypography {
  const AppTypography._();

  /// 拉丁字形族（`pubspec.yaml` 已注册 400/500/600/700 四字重）。
  static const String fontFamily = 'Inter';

  /// 中文回落链（§4.4）：Windows 优先「微软雅黑 UI」，macOS「苹方」，
  /// Linux「思源黑体」。
  static const List<String> fontFamilyFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
  ];

  /// 等宽数字（OpenType `tnum`）：集数 / 时长 / 评分 / 名次 / 百分比。
  static const List<FontFeature> tabularFigures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  // ---------------------------------------------------------------------------
  // 10 级字阶（§4.4 表格逐行对应）
  // ---------------------------------------------------------------------------

  /// 30 / 700 / 1.10 / -0.5 —— 首页头图标题。
  static const TextStyle display = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 1.10,
    letterSpacing: -0.5,
  );

  /// 24 / 600 / 1.20 / -0.3 —— 详情页剧名。
  static const TextStyle h1 = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.20,
    letterSpacing: -0.3,
  );

  /// 20 / 600 / 1.25 / -0.2 —— 分区大标题。
  static const TextStyle h2 = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.25,
    letterSpacing: -0.2,
  );

  /// 17 / 600 / 1.30 / -0.1 —— 卡片组标题。
  static const TextStyle h3 = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.30,
    letterSpacing: -0.1,
  );

  /// 15 / 600 / 1.35 / 0 —— 卡片标题 / 列表主行。
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  /// 14 / 400 / 1.55 / 0 —— 正文。
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.55,
  );

  /// 14 / 600 / 1.45 / 0 —— 强调正文 / 按钮文字。
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.45,
  );

  /// 13 / 500 / 1.40 / 0 —— 次要信息 / 元数据。
  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.40,
  );

  /// 12 / 400 / 1.40 / 0 —— 说明 / 辅助。
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.40,
  );

  /// 11 / 600 / 1.30 / +0.4 —— 大写小标签（「更新至」「广告」）。
  static const TextStyle micro = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.30,
    letterSpacing: 0.4,
  );

  /// 数字专用：与 [label] 同几何，但带等宽数字特性；需要颜色时
  /// `copyWith(color: …)` 或直接用 `context.app.numbers`。
  static const TextStyle numbers = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.40,
    fontFeatures: tabularFigures,
  );

  // ---------------------------------------------------------------------------
  // TextTheme 组装
  // ---------------------------------------------------------------------------

  /// M3 `TextTheme` 槽位映射（本文件唯一的事实来源，`AppTokens` 的具名
  /// getter 按同一张表取值）：
  ///
  /// | 字阶 | 槽位 |
  /// |---|---|
  /// | display | displaySmall（displayLarge/Medium 同值） |
  /// | h1 | headlineMedium（headlineLarge 同值） |
  /// | h2 | headlineSmall |
  /// | h3 | titleLarge |
  /// | title | titleMedium |
  /// | body | bodyMedium |
  /// | bodyStrong | bodyLarge |
  /// | label | labelMedium（titleSmall 同值） |
  /// | caption | bodySmall |
  /// | micro | labelSmall |
  static TextTheme textTheme(AppColors colors) => TextTheme(
    displayLarge: display.copyWith(color: colors.textPrimary),
    displayMedium: display.copyWith(color: colors.textPrimary),
    displaySmall: display.copyWith(color: colors.textPrimary),
    headlineLarge: h1.copyWith(color: colors.textPrimary),
    headlineMedium: h1.copyWith(color: colors.textPrimary),
    headlineSmall: h2.copyWith(color: colors.textPrimary),
    titleLarge: h3.copyWith(color: colors.textPrimary),
    titleMedium: title.copyWith(color: colors.textPrimary),
    titleSmall: label.copyWith(color: colors.textSecondary),
    bodyLarge: bodyStrong.copyWith(color: colors.textPrimary),
    bodyMedium: body.copyWith(color: colors.textPrimary),
    bodySmall: caption.copyWith(color: colors.textSecondary),
    labelLarge: bodyStrong.copyWith(color: colors.textPrimary),
    labelMedium: label.copyWith(color: colors.textSecondary),
    labelSmall: micro.copyWith(color: colors.textTertiary),
  );
}
