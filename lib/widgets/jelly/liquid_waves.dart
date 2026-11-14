import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_metrics.dart';

/// Rail 底部的**液体层**（用户反馈「去掉果冻滴，换成液体」）。
///
/// 与 GravityJellyPool（离散滴 + 弹跳）的区别：这是一整片**连续的水面**——
/// 两层正弦波缓慢起伏叠加，常规状态安静地聚在底部；`slosh()` 时（切 tab）
/// 振幅瞬间放大再缓慢回落，像被人碰了一下的水面。
///
/// - 渲染：CustomPainter 画两层波形 + brand 渐变，无 shader、无 SoftRing；
/// - reduceMotion：波形静止（AC20 延续）；
/// - 高度约 130px，盖在玻璃之上、内容之下（IgnorePointer）。
class RailLiquidWaves extends StatefulWidget {
  const RailLiquidWaves({super.key, this.height = 130});

  /// 液体层高度。
  final double height;

  @override
  State<RailLiquidWaves> createState() => RailLiquidWavesState();
}

class RailLiquidWavesState extends State<RailLiquidWaves>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// 波形相位（秒）。
  double _phase = 0;

  /// slosh 振幅增益（0~1）：切 tab 时置 1，每帧衰减。
  double _slosh = 0;

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = AppMetrics.reduceMotionEnabled(context);
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  /// 外部扰动（切 tab）：振幅瞬间放大再缓慢回落。
  void slosh() {
    if (_reduceMotion || !mounted) return;
    _slosh = 1;
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration elapsed) {
    _phase = elapsed.inMicroseconds / 1e6;
    _slosh *= 0.965; // 每帧衰减，~1.5s 回到平静
    if (_slosh < 0.01 && mounted) setState(() {});
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(painter: _LiquidWavesPainter(_phase, _slosh)),
      ),
    );
  }
}

class _LiquidWavesPainter extends CustomPainter {
  _LiquidWavesPainter(this.phase, this.slosh);

  final double phase;
  final double slosh;

  @override
  void paint(Canvas canvas, Size size) {
    final double amp = 4 + slosh * 16;
    // 第二层波相位差 π/2、振幅略小——叠加出「水面交错起伏」。
    _waveLayer(canvas, size,
        base: size.height * 0.42,
        amp: amp,
        lambda: size.width / 1.6,
        phase: phase * 1.9,
        color: const Color(0x3FFF7A45));
    _waveLayer(canvas, size,
        base: size.height * 0.58,
        amp: amp * 0.8,
        lambda: size.width / 1.1,
        phase: phase * 2.6 + 1.4,
        color: const Color(0x26FFB08A));
  }

  void _waveLayer(
    Canvas canvas,
    Size size, {
    required double base,
    required double amp,
    required double lambda,
    required double phase,
    required Color color,
  }) {
    final Paint paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, size.height * 0.3),
        Offset(0, size.height),
        <Color>[color, color.withValues(alpha: 0)],
      );
    final Path path = Path()..moveTo(0, size.height);
    for (double x = 0; x <= size.width; x += 6) {
      final double y =
          base + math.sin(2 * math.pi * x / lambda + phase) * amp;
      path.lineTo(x, y);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LiquidWavesPainter old) =>
      old.phase != phase || old.slosh != slosh;
}

