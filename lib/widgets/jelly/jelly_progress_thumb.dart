import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 进度条「水滴」thumb（批次③ 果冻手势，交接 T3.3）。
///
/// - 形状：圆润水滴（上尖下圆），静止时正立；
/// - 拖拽中（`activationAnimation` == 1）：横向压扁 8%、纵向拉长 10%，
///   像被两根手指捏着的水珠；
/// - 松手回弹：activation 回落时按阻尼振荡给出 3 次余摆（k=460/c=8 手感档
///   的等效曲线，无自有 ticker——Slider 的动画本身就是值源）。
///
/// 颜色由调用方传（`SliderComponentShape` 拿不到 BuildContext）：播放器传
/// `context.app.colors.brand`，测试可直接传常量。
/// 不参与手势竞技场（Slider 自己处理拖拽），只在 paint 层变形。
class JellyProgressThumb extends SliderComponentShape {
  const JellyProgressThumb({
    required this.color,
    this.radius = 8,
    this.squashStrength = 0.08,
  });

  /// 水滴本体色。
  final Color color;

  /// 静止半径。
  final double radius;

  /// 拖拽时的横向压缩比例。
  final double squashStrength;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius * 1.5);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final double t = activationAnimation.value.clamp(0.0, 1.0);
    // 松手余摆：把 (1-t) 当作衰减相位，sin 产生 3 次过零（与 JellyPress
    // 「crossing ≥ 3」的视觉等效），幅度随衰减归零。拖拽中 t==1 无余摆。
    final double release = 1 - t;
    final double wobble = math.sin(release * math.pi * 3) * release * 0.09;
    final double squashX = 1 - squashStrength * t + wobble;
    final double squashY = 1 + squashStrength * 1.25 * t - wobble;
    // disabled 时缩到 80%（enableAnimation 1=启用）。
    final double r = radius * (0.8 + 0.2 * enableAnimation.value);

    final Path path = _droplet(r);
    final Paint fill = Paint()..color = color;
    // 拖拽时加一点投影：水珠「被捏起来」的感觉。
    if (t > 0.01) {
      context.canvas
          .drawShadow(path.shift(center), ui.Color(0x42000000), 6 * t, false);
    }
    context.canvas.save();
    context.canvas.translate(center.dx, center.dy);
    context.canvas.scale(squashX, squashY);
    context.canvas.drawPath(path, fill);
    // 高光点：水珠左上的反光。
    context.canvas.drawCircle(
      Offset(-r * 0.35, -r * 0.45),
      r * 0.22,
      Paint()..color = ui.Color(0x66FFFFFF),
    );
    context.canvas.restore();
  }

  /// 以原点为中心的水滴：上半是汇聚的尖，下半是半圆。
  Path _droplet(double r) {
    return Path()
      ..moveTo(0, -r * 1.55)
      ..quadraticBezierTo(r * 0.92, -r * 0.28, r * 0.92, r * 0.18)
      ..arcToPoint(
        Offset(-r * 0.92, r * 0.18),
        radius: Radius.circular(r * 0.92),
        largeArc: true,
      )
      ..quadraticBezierTo(-r * 0.92, -r * 0.28, 0, -r * 1.55)
      ..close();
  }
}
