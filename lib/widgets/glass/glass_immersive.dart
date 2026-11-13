import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../theme/glass_tokens.dart';
import 'app_glass.dart';

/// 播放器沉浸玻璃带。
///
/// 本批只交付组件与参数，`lib/screens/player_screen.dart` 由 ③ 接线，本文件
/// 不引用播放器的任何状态。
///
/// 与另外两档（nav / overlay）的区别只有两点：
/// 1. 玻璃**下面**先铺一层 scrim。视频画面可能整屏亮白，不发光的玻璃撑不住
///    文字对比度——这是 §11.5 第 3 条，也是 AC1b.7 的图片来源；
/// 2. 文字前景由调用方保证：玻璃上一律 `textPrimary` / `textSecondary`，
///    不得用 `textTertiary`（背景透出后必然不可读，§12）。[foregroundColor]
///    把这条约定变成一个可直接用的取值口。
class GlassImmersiveBar extends StatelessWidget {
  const GlassImmersiveBar({
    super.key,
    required this.child,
    this.padding,
    this.radius,
    this.scrimOpacity,
  });

  /// 玻璃面上的内容（播放器 OSD 的按钮 / 进度 / 标题）。
  final Widget child;

  /// 内容内边距；`null` 表示由调用方自己排版。
  final EdgeInsetsGeometry? padding;

  /// 圆角；`null` 取 `metrics.radiusMd`（与 `AppGlass` 的沉浸档默认一致）。
  ///
  /// 非统一圆角（例如贴在画面底部、只圆上方两角）由本组件补一层裁剪。
  final BorderRadius? radius;

  /// scrim 不透明度；`null` 取 [defaultScrimOpacity]，超出 0–1 会被钳住。
  final double? scrimOpacity;

  /// 播放器 scrim 的默认不透明度（§11.5 第 3 条的经验值）。
  static const double defaultScrimOpacity = 0.55;

  /// 玻璃面上的文字色。
  Color foregroundColor(BuildContext context) => context.app.colors.textPrimary;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final BorderRadius shape =
        radius ?? BorderRadius.all(Radius.circular(m.radiusMd));
    final double opacity = (scrimOpacity ?? defaultScrimOpacity)
        .clamp(0.0, 1.0)
        .toDouble();

    // 播放器专用 scrim：先把视频画面的亮度压下去，玻璃才谈得上「字读得清」。
    // 这**不是**全站色彩 Token —— 全站表面体系只有 canvas / surface1..3（§12），
    // scrim 只服务播放器沉浸层，所以就地取纯黑 + 不透明度，不进
    // `app_color.dart`；③ 接入播放器时若定出 `player_overlay_theme.dart` 的
    // Token，再把这里换过去。
    final BoxDecoration scrim = BoxDecoration(
      color: Colors.black.withValues(alpha: opacity),
      borderRadius: shape,
    );

    final bool uniform =
        shape.topLeft == shape.topRight &&
        shape.topLeft == shape.bottomLeft &&
        shape.topLeft == shape.bottomRight;
    Widget glass = AppGlass(
      tier: AppGlassTier.immersive,
      radius: shape.topLeft.x,
      padding: padding,
      child: child,
    );
    if (!uniform) {
      // `AppGlass` 只吃统一圆角；只圆上方两角时用一层裁剪把下沿切平。
      // 裁剪不改采样原点，不是 §11.5 第 1 条禁止的 saveLayer。
      glass = ClipRRect(borderRadius: shape, child: glass);
    }

    // 先 scrim 后玻璃：`DecoratedBox` 的底色画在 child 之前，顺序天然正确，
    // 也不需要额外的 Stack / Opacity（后者会重新开 saveLayer）。
    return DecoratedBox(decoration: scrim, child: glass);
  }
}
