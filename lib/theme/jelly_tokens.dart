import 'package:flutter/material.dart';

import '../core/soft_body/soft_ring.dart';

/// 果冻手感三档（对应 `design.md §13.3`）。
///
/// 业务代码只选档位，**不要**手写 `JellyPhysics` 的六个参数。
enum JellyPreset {
  /// 弹、脆：按钮 / chip / Tab / 开关。
  snap,

  /// 软、慢：卡片 hover / 拖拽 / 面板展开。
  flow,

  /// 流动感：播放器手势反馈 / Toast。
  melt,
}

extension JellyPresetX on JellyPreset {
  JellyPhysics get physics => switch (this) {
    JellyPreset.snap => JellyPhysics.snap,
    JellyPreset.flow => JellyPhysics.flow,
    JellyPreset.melt => JellyPhysics.melt,
  };
}

/// 果冻材质（"实心果冻"路线：有色、有厚度、高光明显）。
///
/// 不用 `BackdropFilter`：按钮/卡片的背后通常是纯色，模糊采样不到东西，
/// 白付一次全屏 filter 开销（`design.md §13.4` 的判定规则）。
/// 需要透背景时由调用方传 `backdropBlur: true` 给 `JellySurface`。
@immutable
class JellyMaterial {
  const JellyMaterial({
    required this.base,
    required this.light,
    required this.dark,
    required this.shadow,
    required this.rim,
    required this.gloss,
  });

  /// 由主色派生：上亮、下暗、外投影、边缘高光、顶部反光。
  factory JellyMaterial.fromBase(
    Color base, {
    Color highlightBase = Colors.white,
  }) {
    return JellyMaterial(
      base: base,
      light: Color.lerp(base, highlightBase, 0.28)!,
      dark: Color.lerp(base, Colors.black, 0.28)!,
      shadow: base.withValues(alpha: 0.55),
      rim: highlightBase.withValues(alpha: 0.45),
      gloss: highlightBase.withValues(alpha: 0.26),
    );
  }

  /// 主色（渐变中段）。
  final Color base;

  /// 顶部亮阶。
  final Color light;

  /// 底部暗阶。
  final Color dark;

  /// 外投影色。
  final Color shadow;

  /// 1px 边缘高光。
  final Color rim;

  /// 顶部反光带。
  final Color gloss;

  JellyMaterial copyWith({Color? base, Color? light, Color? dark}) =>
      JellyMaterial(
        base: base ?? this.base,
        light: light ?? this.light,
        dark: dark ?? this.dark,
        shadow: shadow,
        rim: rim,
        gloss: gloss,
      );
}
