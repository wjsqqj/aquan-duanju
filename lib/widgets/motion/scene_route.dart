import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../theme/player_overlay_theme.dart';
import 'fx_curves.dart';

/// 裁切线「开演」转场（effect-atlas crop-line-page-transition 降编移植 · E1）。
///
/// 详情 → 播放器的 PageRoute，**单一进度驱动**（线与裁切共享一个值，交叉点
/// 不停顿），分两段：
///
/// - **close**（[AppMetrics.fxSceneClose] 480ms，`Curves.easeIn`，越近十字越快）：
///   纯黑幕渐入，四条 brand 色细线从四边压向屏幕中心成十字；播放器子树全程
///   被 ClipRect 钉成零尺寸（不可见）。旧页不做裁切——Flutter 路由模型下
///   上一页不可控，黑幕盖住即达成「旧页被裁没」的读感（design §7 简化）。
/// - **open**（[AppMetrics.fxSceneOpen] 520ms，[Fx.glideOut]，快出软落）：
///   线沿原方向穿透到对边并在后 30% 淡出；播放器自中心向外揭示（ClipRect
///   inset 扩张）；黑幕在前 40% 淡出让内容透出。
///
/// pop 同一路径反放（reverseTransitionDuration 与 transitionDuration 相同）。
///
/// 「减少动效」由**调用方**分流（`AppMetrics.reduceMotionEnabled` 为真时构造
/// 旧 MaterialPageRoute，见 detail_screen 的 `_play`）：路由无 Element 上下文，
/// 本类不自门控。
///
/// 合法性（播放器内红线）：转场 overlay 只用 transform + opacity + ClipRect +
/// CustomPaint 画线，零玻璃/BackdropFilter/着色器。黑幕取
/// `PlayerOverlayTokens.videoBlack`（播放器既有黑底语义口，不新增裸色值）。
/// 编排豁免登记（DESIGN.md §6）：close 480 + open 520 ≈ 1.0s ≤ 2.4s 上限。
class FxSceneRoute<T> extends PageRouteBuilder<T> {
  FxSceneRoute({required WidgetBuilder builder, super.settings})
    : super(
        opaque: true,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionDuration: _totalDuration,
        reverseTransitionDuration: _totalDuration,
        transitionsBuilder: _transition,
      );

  /// 转场总时长。路由属性在无 Element 处读取，而度量与亮度无关
  /// （AppMetrics.lerpFrom 是离散切换），所以取 const standard 实例。
  static Duration get _totalDuration =>
      AppMetrics.standard.fxSceneClose + AppMetrics.standard.fxSceneOpen;

  /// close 段在总进度里的占比（480/1000）。
  static double get _closeFraction =>
      AppMetrics.standard.fxSceneClose.inMicroseconds /
      _totalDuration.inMicroseconds;

  /// 黑幕在 open 段淡出的窗口（前 40% 完成，让内容透出）。
  static const double _kScrimFadeOutWindow = 0.4;

  /// 线在 close 段的淡入窗口（前 25% 完成成可见，避免边缘突现）。
  static const double _kLineFadeInWindow = 0.25;

  /// 线在 open 段开始淡出的位置（后 30% 淡出，atlas 规格）。
  static const double _kLineFadeOutStart = 0.7;

  static Widget _transition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final double t = animation.value;
        final double closeFraction = _closeFraction;
        final double close;
        final double open;
        if (t < closeFraction) {
          close = Curves.easeIn.transform((t / closeFraction).clamp(0.0, 1.0));
          open = 0;
        } else {
          close = 1;
          final double span = 1.0 - closeFraction;
          open = Fx.glideOut.transform(
            ((t - closeFraction) / span).clamp(0.0, 1.0),
          );
        }
        final AppTokens tokens = context.app;
        final double scrimOpacity = close < 1.0
            ? close
            : 1.0 - (open / _kScrimFadeOutWindow).clamp(0.0, 1.0);
        final double lineOpacity =
            (close / _kLineFadeInWindow).clamp(0.0, 1.0) *
            (1.0 -
                ((open - _kLineFadeOutStart) / (1.0 - _kLineFadeOutStart))
                    .clamp(0.0, 1.0));
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 播放器内容：自中心向外揭示（close 段钉成零尺寸）。
            ClipRect(clipper: _CenterRevealClipper(open), child: child),
            // 黑幕：close 段盖住旧页；open 段前 40% 淡出。
            if (scrimOpacity > 0)
              ColoredBox(
                color: PlayerOverlayTokens.videoBlack.withValues(
                  alpha: scrimOpacity.clamp(0.0, 1.0),
                ),
              ),
            // 四条 brand 细线：压向中心 → 穿透到对边淡出。
            Positioned.fill(
              child: CustomPaint(
                painter: _CrossLinesPainter(
                  close: close,
                  open: open,
                  opacity: lineOpacity,
                  color: tokens.colors.brand,
                  strokeWidth: tokens.metrics.hairline,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 转场几何纯函数：给定分段进度（close/open ∈ [0,1]）返回四条线的端点对
/// （横、横、竖、竖）。独立成函数便于 0/0.5/1 三帧的进度派生测试。
///
/// - close：线从四边压向中心，距中心 = (1-close)·半边长；
/// - open：沿原方向穿透到对边，再走 open·半边长（越界即出屏）；
/// - 线长固定 = min(所在边长, 40% 短边)，交叉点在屏幕中心。
@visibleForTesting
List<(Offset, Offset)> fxSceneCrossLines(Size size, double close, double open) {
  final double w = size.width;
  final double h = size.height;
  final double cx = w / 2;
  final double cy = h / 2;
  final double hLineLength = math.min(
    w,
    _kLineShortSideFactor * math.min(w, h),
  );
  final double vLineLength = math.min(
    h,
    _kLineShortSideFactor * math.min(w, h),
  );
  final double travelH = h / 2;
  final double travelW = w / 2;
  final double topY = cy - (1 - close) * travelH + open * travelH;
  final double bottomY = cy + (1 - close) * travelH - open * travelH;
  final double leftX = cx - (1 - close) * travelW + open * travelW;
  final double rightX = cx + (1 - close) * travelW - open * travelW;
  return <(Offset, Offset)>[
    (Offset(cx - hLineLength / 2, topY), Offset(cx + hLineLength / 2, topY)),
    (
      Offset(cx - hLineLength / 2, bottomY),
      Offset(cx + hLineLength / 2, bottomY),
    ),
    (Offset(leftX, cy - vLineLength / 2), Offset(leftX, cy + vLineLength / 2)),
    (
      Offset(rightX, cy - vLineLength / 2),
      Offset(rightX, cy + vLineLength / 2),
    ),
  ];
}

/// 线长取 40% 短边（atlas crop-line 规格）。
const double _kLineShortSideFactor = 0.4;

/// 中心揭示裁切：open ∈ [0,1]，0 = 零尺寸（不可见），1 = 全尺寸。
class _CenterRevealClipper extends CustomClipper<Rect> {
  const _CenterRevealClipper(this.open);

  final double open;

  @override
  Rect getClip(Size size) => Rect.fromCenter(
    center: Offset(size.width / 2, size.height / 2),
    width: size.width * open,
    height: size.height * open,
  );

  @override
  bool shouldReclip(_CenterRevealClipper oldClipper) => oldClipper.open != open;
}

/// 四条 brand 细线的绘制：位置纯由分段进度派生（[fxSceneCrossLines]）。
class _CrossLinesPainter extends CustomPainter {
  _CrossLinesPainter({
    required this.close,
    required this.open,
    required this.opacity,
    required this.color,
    required this.strokeWidth,
  });

  final double close;
  final double open;
  final double opacity;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final Paint linePaint = Paint()
      ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0))
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    for (final (Offset a, Offset b) in fxSceneCrossLines(size, close, open)) {
      canvas.drawLine(a, b, linePaint);
    }
  }

  // 纯装饰 overlay：绝不能认领命中。CustomPainter.hitTest 缺省返回 null，
  // RenderCustomPaint.hitTestSelf 把 null 当 true——四线 painter 位于转场
  // Stack 最顶层且落定后仍常驻（opacity 0），不改写会把整个播放器页面的
  // 鼠标/hover 命中全部吃掉（键盘焦点树不受影响，故真机只见「键盘可用、
  // 鼠标全哑」）。E8 复验发现并修复。
  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_CrossLinesPainter oldDelegate) =>
      oldDelegate.close != close ||
      oldDelegate.open != open ||
      oldDelegate.opacity != opacity ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
