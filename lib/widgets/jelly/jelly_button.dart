import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../theme/jelly_tokens.dart';
import 'jelly_surface.dart';

/// 果冻按钮：按下挤压、松手回弹，材质是"实心果冻"（渐变 + 反光 + 边缘高光）。
///
/// 交互四态仍由 [JellySurface] 内部统一处理（hover 提亮、pressed 挤压、
/// disabled 半透明、focus 由外层 `AppInteractive` 或 `Focus` 负责），
/// 这里只负责「尺寸 + 文字/图标排版」。
class JellyButton extends StatelessWidget {
  const JellyButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color,
    this.preset = JellyPreset.snap,
    this.size,
    this.expanded = false,
    this.tooltip,
    this.enabled = true,
  });

  /// 按钮文字。
  final String label;

  /// 可选前置图标（调用方取 `AppIcons`）。
  final IconData? icon;

  final VoidCallback? onTap;

  /// 主色；`null` 取主题 `brand`。
  final Color? color;

  final JellyPreset preset;

  /// 显式尺寸；`null` 时按文字长度估算胶囊（高 44）。
  final Size? size;

  /// 是否撑满父级宽度。
  final bool expanded;

  final String? tooltip;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final double height = size?.height ?? 44;
    final double fontSize = tokens.body.fontSize ?? 14;

    // 粗估文字宽度：中文按 1em、西文按 0.55em，避免每次都上 TextPainter
    var textWidth = 0.0;
    for (final rune in label.runes) {
      textWidth += rune > 0x2E80 ? fontSize : fontSize * 0.55;
    }
    final double iconWidth = icon == null ? 0 : (fontSize + 6);
    final double horizontal = tokens.metrics.s24 * 2;
    final double estimated = textWidth + iconWidth + horizontal;

    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: fontSize + 4, color: tokens.colors.onBrand),
          SizedBox(width: tokens.metrics.s6),
        ],
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tokens.bodyStrong.copyWith(color: tokens.colors.onBrand),
        ),
      ],
    );

    final Widget button = JellySurface(
      size: size ?? Size(estimated, height),
      preset: preset,
      color: color ?? tokens.colors.brand,
      tooltip: tooltip ?? label,
      enabled: enabled && onTap != null,
      onTap: enabled ? onTap : null,
      child: content,
    );

    if (!expanded) return button;
    return LayoutBuilder(
      builder: (context, constraints) => JellySurface(
        size: Size(constraints.maxWidth, height),
        preset: preset,
        color: color ?? tokens.colors.brand,
        tooltip: tooltip ?? label,
        enabled: enabled && onTap != null,
        onTap: enabled ? onTap : null,
        child: content,
      ),
    );
  }
}
