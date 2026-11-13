import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'jelly_press.dart';

/// 果冻 chip（批次⑤ 补全「按钮、chip 用果冻」的 chip 位型）。
///
/// 与 [JellySurface]（软体）的区别：chip 满屏都是（频道条/筛选条一次 4–8 枚），
/// 18 点软体每枚一个实例会破 D15 的「同屏 SoftRing ≤ 3」预算——所以这里用
/// [JellyPress] 的 1D 弹簧（零软体、静止不排帧）驱动挤压，凝胶观感用
/// 「上亮下暗 + 顶部反光」的渐变贴出来。
///
/// API 对齐 `ChoiceChip`（label / selected / onSelected），调用点可机械替换。
class JellyChip extends StatelessWidget {
  const JellyChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final Color base = selected ? tokens.colors.brand : tokens.colors.surface2;
    final Color fg = selected ? tokens.colors.onBrand : tokens.colors.textSecondary;

    final Widget pill = JellyPress(
      strength: 0.06,
      child: AnimatedContainer(
        duration: AppMetrics.reduceMotionOf(context, m.micro),
        curve: m.microCurve,
        height: m.s32,
        padding: EdgeInsets.fromLTRB(m.s12, m.s4, m.s12, m.s4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
          border: Border.all(
            color: selected ? tokens.colors.brand : tokens.colors.hairline,
            width: m.hairline,
          ),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Color.lerp(base, Colors.white, 0.18)!,
                    base,
                    Color.lerp(base, Colors.black, 0.14)!,
                  ],
                  stops: const <double>[0.0, 0.52, 1.0],
                )
              : null,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tokens.label.copyWith(color: fg),
        ),
      ),
    );

    final Widget chip = MouseRegion(
      cursor:
          onSelected != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        child: pill,
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: chip);
    }
    return Semantics(
      button: true,
      selected: selected,
      child: chip,
    );
  }
}
