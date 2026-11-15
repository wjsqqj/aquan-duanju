import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../ui/avatar_walk_loading.dart' show GroundDashes;
import 'jelly_progress_thumb.dart' show dropletPath;

/// 全站统一进度条（批次 B1，implement.md「JellyProgressBar + 11 处收编」）。
///
/// **组合实现**（非系统线性进度条的继承封装，自有绘制），两种语义：
/// - 确定态（`value != null`）：surface3 胶囊轨道 + 品牌橙填充 + 前端水滴帽
///   （[dropletPath] 语言）；value 变化经 `hover`（150ms easeOut）隐式动画；
/// - 不确定态（`value == null`）：轨道内 [GroundDashes] 左移（90px/s，
///   与走路小人地面虚线同一语言）——「小人在跑」的进度隐喻。
///
/// reduceMotion：确定态时长归零（值驱动本就静止安全）；不确定态停帧为
/// 静态虚线。语义：确定 = `进度 / 68%`，不确定 = `加载中`。
class JellyProgressBar extends StatefulWidget {
  const JellyProgressBar({super.key, this.value, this.color});

  /// 0~1 的进度；`null` 表示不确定态。
  final double? value;

  /// 填充/水滴/虚线色；缺省取品牌橙（深色视频上下文可覆盖，如 `Colors.white`）。
  final Color? color;

  @override
  State<JellyProgressBar> createState() => _JellyProgressBarState();
}

class _JellyProgressBarState extends State<JellyProgressBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _t = 0;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncTicker();
  }

  @override
  void didUpdateWidget(JellyProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// 只有不确定态 + 未开启 reduceMotion 才跑虚线；其余一律停帧。
  void _syncTicker() {
    final bool animate = widget.value == null && !_reduceMotion;
    if (animate) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (mounted) setState(() => _t = elapsed.inMicroseconds / 1e6);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final Color trackColor = tokens.colors.surface3;
    final Color fillColor = widget.color ?? tokens.colors.brand;

    final Widget bar = widget.value == null
        ? _buildIndeterminate(m, trackColor, fillColor)
        : _buildDeterminate(m, trackColor, fillColor);

    return Semantics(
      label: widget.value == null ? '加载中' : '进度',
      value: widget.value == null ? null : '${_percentOf(widget.value!)}%',
      textDirection: Directionality.of(context),
      child: bar,
    );
  }

  static int _percentOf(double value) => (value.clamp(0.0, 1.0) * 100).round();

  /// 确定态：胶囊轨道 + 填充 + 水滴帽，value 变化 150ms easeOut 隐式动画。
  ///
  /// TweenAnimationBuilder 首帧 begin==end 不做入场动画，只对后续变化生效；
  /// 水滴帽在 0% / 100% 时隐藏（半颗挂在端点外没有意义）。
  Widget _buildDeterminate(AppMetrics m, Color trackColor, Color fillColor) {
    final double v = widget.value!.clamp(0.0, 1.0);
    return SizedBox(
      height: m.s6,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: v, end: v),
        duration: AppMetrics.reduceMotionOf(context, m.hover),
        curve: m.hoverCurve,
        builder: (BuildContext context, double t, Widget? child) {
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ColoredBox(color: trackColor),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: t,
                          child: ColoredBox(color: fillColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (t > 0 && t < 1)
                Align(
                  alignment: Alignment(2 * t - 1, 0),
                  child: CustomPaint(
                    size: Size(m.s4 * 1.84, m.s4 * 2.65),
                    painter: _DropletCapPainter(color: fillColor, radius: m.s4),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 不确定态：胶囊轨道内地面虚线左移（90px/s 同语言）；
  /// reduceMotion 停帧为 shift=0 的静态虚线。
  Widget _buildIndeterminate(AppMetrics m, Color trackColor, Color fillColor) {
    final double shift = _reduceMotion ? 0 : (_t * 90) % 26;
    return ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
      child: SizedBox(
        height: m.s6,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: trackColor),
            Positioned.fill(
              child: CustomPaint(
                painter: GroundDashes(shift: shift, color: fillColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 前端水滴帽：把 [dropletPath] 画进自身包围盒（宽 1.84r · 高 2.65r），
/// 便于 [Align] 以包围盒中心对齐轨道上的进度位置。
class _DropletCapPainter extends CustomPainter {
  const _DropletCapPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    // 路径包围盒 y ∈ [-1.55r, +1.1r]，中心偏上 0.225r；平移使包围盒
    // 恰好铺满 [size]，Align 才能把它准确钉在进度前沿。
    canvas.translate(size.width / 2, size.height / 2 + radius * 0.225);
    canvas.drawPath(dropletPath(radius), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _DropletCapPainter old) =>
      old.color != color || old.radius != radius;
}
