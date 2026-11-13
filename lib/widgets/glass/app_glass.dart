import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/app_color.dart';
import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../theme/glass_tokens.dart';

/// 液态玻璃门面（design.md §11.3 / §11.4 / §12）。
///
/// 业务代码（外壳、浮层、播放器）**只碰这个组件**：
/// - 档位由 [tier] 选，参数取自 `lib/theme/glass_tokens.dart`；
/// - 有 Impeller 时走上游折射玻璃，没有时自动降级为雾面玻璃；
/// - 两条分支都叠一层 `colors.surface3` 半透明底托，保护文字对比度；
/// - 圆角与描边全部来自 `context.app.metrics`，不写裸数字。
///
/// 文字前景色由调用方负责（玻璃上一律 `textPrimary` / `textSecondary`，
/// 不得用 `textTertiary`）。
class AppGlass extends StatelessWidget {
  const AppGlass({
    super.key,
    required this.child,
    this.tier = AppGlassTier.overlay,
    this.radius,
    this.padding,
    this.tint,
    this.clipBehavior,
  });

  /// 玻璃面上的内容。
  final Widget child;

  /// 档位：决定 8 个材质参数与默认圆角。
  final AppGlassTier tier;

  /// 圆角；`null` 取该档位在 [AppMetrics] 里的对应圆角。
  final double? radius;

  /// 内容内边距；`null` 表示由调用方自己排版。
  final EdgeInsetsGeometry? padding;

  /// 底托色；`null` 表示按档位取 `colors.surface3` 半透明。
  final Color? tint;

  /// 子内容裁剪方式；`null` 时折射分支用 [Clip.antiAlias]。
  final Clip? clipBehavior;

  /// 仅供测试与降级验证：强制走无折射分支（AC1b.6）。
  ///
  /// 置 `true` 后外观退化为 `BackdropFilter` 雾面玻璃，用来在没有 Impeller 的
  /// 机器（或 widget 测试）上验证降级不破版 —— 不依赖换一台设备才能测。
  static bool debugForceFallback = false;

  /// 能力真源：Impeller（ShaderFilter 可用）为 `true`，Skia / 测试环境为 `false`。
  static bool get canRefract =>
      !debugForceFallback && ui.ImageFilter.isShaderFilterSupported;

  /// 档位默认圆角，取值全部来自 [AppMetrics]：
  /// 导航 = 面板圆角、浮层 = 大容器圆角、沉浸 = 卡片圆角。
  static double _defaultRadius(AppGlassTier tier, AppMetrics metrics) =>
      switch (tier) {
        AppGlassTier.nav => metrics.radiusLg,
        AppGlassTier.overlay => metrics.radiusXl,
        AppGlassTier.immersive => metrics.radiusMd,
      };

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppColors colors = tokens.colors;
    final AppMetrics metrics = tokens.metrics;
    final Brightness brightness = Theme.of(context).brightness;

    final GlassThemeSettings settings = settingsFor(tier, brightness);
    final double resolvedRadius = radius ?? _defaultRadius(tier, metrics);
    final BorderRadius borderRadius = BorderRadius.all(
      Radius.circular(resolvedRadius),
    );
    final Color backing = tint ?? glassBacking(colors.surface3, brightness);
    final Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    if (canRefract) {
      // 折射分支：上游 `GlassContainer` 自带 shader 折射。`useOwnLayer: true`
      // 才能让我们传的 `settings` 生效（分组模式会忽略 per-widget settings）。
      // 上游基线取 iOS 26 预设，`lensModel` 因此由 `GlassStyle.ios26` 决定。
      // 注：该预设自带具体 `shadow` 列表，上游此时以列表为准；表格里的
      // `shadowElevation` 只是把这档取值钉住，不额外改阴影形态。
      return GlassContainer(
        useOwnLayer: true,
        settings: settings.applyTo(
          brightness == Brightness.dark
              ? LiquidGlassSettings.ios26Dark
              : LiquidGlassSettings.ios26Light,
        ),
        shape: LiquidRoundedSuperellipse(borderRadius: resolvedRadius),
        clipBehavior: clipBehavior ?? Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(color: backing, borderRadius: borderRadius),
          child: content,
        ),
      );
    }

    // 降级分支（§11.4）：不用上游任何玻璃 widget。
    // `BackdropFilter` 的 sigma 取档位 blur 的两倍 + `surface3` 半透明底托
    // + 1px `hairline` 描边，视觉上是雾面玻璃、无折射。
    final double sigma = (settings.blur ?? 0) * 2;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backing,
            borderRadius: borderRadius,
            border: Border.all(color: colors.hairline, width: metrics.hairline),
          ),
          child: content,
        ),
      ),
    );
  }
}
