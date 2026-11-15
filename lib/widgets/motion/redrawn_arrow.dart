import 'dart:ui' show PathMetric, PathMetrics;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_curves.dart';
import 'fx_stagger.dart';

/// 悬停重画箭头（effect-atlas redrawn-arrow-hover 移植 · E2）。
///
/// 桌面 hover 时「旧箭头加速擦除 + 新箭头减速重画」：
/// - 旧箭头（杆+倒钩合一 Path）自尾部擦除并向前进给——`Curves.easeInCubic`
///   加速离场，[AppMetrics.hover]（150ms）档；
/// - 新箭头原位重画，**杆先**、倒钩 lag [fxMotionLag]（60ms）一拍伸出，
///   [Fx.glide] 减速落定，[AppMetrics.panel]（250ms）档；
/// - 重画在擦除起跑后 60ms 起跑（atlas「重叠 60ms 无空帧」——旧箭头
///   静止画在底层垫着，重画叠在上层，全程无空档）；
/// - 离开瞬间复位不播退场动画（controller 直接归零）。
///
/// 时长纪律：erase=hover 档、draw=panel 档，lag 用 [fxMotionLag]——保持
/// atlas 的相对节奏（加速擦除 vs 减速重画对比）但锁五档；曲线走 [Fx] 族
/// 与 `Curves.easeInCubic`（无裸 Cubic）。
///
/// 门控（AC20）：仅桌面且非 reduceMotion 才装控制器；否则**静态透传**
/// [icon]（保持调用处 IconButton 结构，移动/TV 渲染与改前逐像素一致）。
/// 桌面 idle 态画满箭头（atlas「双份箭头 painter 叠放」的旧箭头）。
class FxRedrawnArrow extends StatefulWidget {
  const FxRedrawnArrow({super.key, required this.icon, this.color, this.size});

  /// 非动效路径的静态图标（移动/TV/reduceMotion 原样透传）。
  final Widget icon;

  /// 桌面绘制色；缺省取 `IconTheme.of(context).color`（IconButton 禁用态
  /// 的降透明会经由 IconTheme 自动同步）。
  final Color? color;

  /// 绘制边长；缺省取 `IconTheme.of(context).size`（缺省 24）。
  final double? size;

  @override
  State<FxRedrawnArrow> createState() => _FxRedrawnArrowState();
}

class _FxRedrawnArrowState extends State<FxRedrawnArrow>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  /// erase/shaft/barb 三路进度（同一 controller 的三段窗口）。
  late final Animation<double> _erase;
  late final Animation<double> _shaft;
  late final Animation<double> _barb;

  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    // 桌面判定走 Theme.platform（MaterialApp 缺省 = defaultTargetPlatform；
    // 测试可用 ThemeData(platform:) 注入，不动 debug 全局变量）。
    final bool desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    // 门控：桌面 + 非 reduceMotion 才建控制器（移动端零开销，不装 Ticker）。
    if (!desktop || AppMetrics.reduceMotionEnabled(context)) return;
    final AppMetrics m = context.app.metrics;
    // 总时长 = 擦除起跑 → 倒钩 lag 一拍 → 重画落定（lag×2 + panel）。
    final Duration total = fxMotionLag * 2 + m.panel;
    final double totalMs = total.inMilliseconds.toDouble();
    _controller = AnimationController(vsync: this, duration: total);
    final double eraseEnd = m.hover.inMilliseconds / totalMs;
    final double shaftBegin = fxMotionLag.inMilliseconds / totalMs;
    final double shaftEnd = (fxMotionLag + m.panel).inMilliseconds / totalMs;
    final double barbBegin = (fxMotionLag * 2).inMilliseconds / totalMs;
    _erase = CurvedAnimation(
      parent: _controller!,
      curve: Interval(0, eraseEnd, curve: Curves.easeInCubic),
    );
    _shaft = CurvedAnimation(
      parent: _controller!,
      curve: Interval(shaftBegin, shaftEnd, curve: Fx.glide),
    );
    _barb = CurvedAnimation(
      parent: _controller!,
      curve: Interval(barbBegin, 1, curve: Fx.glide),
    );
  }

  void _onEnter(PointerEnterEvent _) => _controller?.forward(from: 0);

  /// 离开瞬间复位：不播退场动画（atlas 规格），静止画满旧箭头。
  void _onExit(PointerExitEvent _) => _controller?.value = 0;

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (controller == null) return widget.icon;
    final IconThemeData theme = IconTheme.of(context);
    // IconTheme 色（IconButton 禁用态降透明会同步）；兜底取主题主文字色。
    final Color color =
        widget.color ?? theme.color ?? context.app.colors.textPrimary;
    final double size = widget.size ?? theme.size ?? 24;
    final AppMetrics m = context.app.metrics;
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => CustomPaint(
          size: Size.square(size),
          painter: RedrawnArrowPainter.old(
            erase: _erase.value,
            shiftPx: m.s4,
            color: color,
            strokeWidth: m.hairline * 1.5,
          ),
          foregroundPainter: RedrawnArrowPainter.newArrow(
            shaft: _shaft.value,
            barb: _barb.value,
            color: color,
            strokeWidth: m.hairline * 1.5,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/redrawn_arrow_test.dart）----

  @visibleForTesting
  double get debugEraseT => _erase.value;

  @visibleForTesting
  double get debugShaftT => _shaft.value;

  @visibleForTesting
  double get debugBarbT => _barb.value;

  @visibleForTesting
  bool get debugAnimated => _controller != null;
}

/// 箭头几何（24×24 逻辑视口，按画布边长等比放大）：杆为水平线段（右向），
/// 倒钩是从尖端向后上/后下的两段折线。公开为 [RedrawnArrowPainter] 以便
/// 纯几何测试；widget 内部叠两份（painter 旧箭头 + foregroundPainter 新箭头）。
class RedrawnArrowPainter extends CustomPainter {
  RedrawnArrowPainter._({
    required this.mode,
    required this.erase,
    required this.shiftPx,
    required this.shaft,
    required this.barb,
    required this.color,
    required this.strokeWidth,
  });

  /// 旧箭头：erase = 擦除进度（0=静止满箭头，1=完全擦除）。
  factory RedrawnArrowPainter.old({
    required double erase,
    required Color color,
    required double strokeWidth,
    double shiftPx = 0,
  }) => RedrawnArrowPainter._(
    mode: RedrawnArrowMode.oldArrow,
    erase: erase,
    shiftPx: shiftPx,
    shaft: 1,
    barb: 1,
    color: color,
    strokeWidth: strokeWidth,
  );

  /// 新箭头：杆 [shaft] 与倒钩 [barb] 各自的重画进度（杆先、倒钩 lag 一拍）。
  factory RedrawnArrowPainter.newArrow({
    required double shaft,
    required double barb,
    required Color color,
    required double strokeWidth,
  }) => RedrawnArrowPainter._(
    mode: RedrawnArrowMode.newArrow,
    erase: 0,
    shiftPx: 0,
    shaft: shaft,
    barb: barb,
    color: color,
    strokeWidth: strokeWidth,
  );

  final RedrawnArrowMode mode;
  final double erase;
  final double shiftPx;
  final double shaft;
  final double barb;
  final Color color;
  final double strokeWidth;

  /// 杆：(4,12) → (20,12)。
  static const Offset _shaftA = Offset(4, 12);
  static const Offset _shaftB = Offset(20, 12);

  /// 倒钩：尖端向后上 (13,5.5) 与向后下 (13,18.5)。
  static const Offset _barbUp = Offset(13, 5.5);
  static const Offset _barbDown = Offset(13, 18.5);

  /// 24×24 视口内的合一旧箭头 Path（杆 → 上钩 → 下钩，擦除序）。
  static Path _oldArrow() => Path()
    ..moveTo(_shaftA.dx, _shaftA.dy)
    ..lineTo(_shaftB.dx, _shaftB.dy)
    ..lineTo(_barbUp.dx, _barbUp.dy)
    ..moveTo(_shaftB.dx, _shaftB.dy)
    ..lineTo(_barbDown.dx, _barbDown.dy);

  @override
  void paint(Canvas canvas, Size size) {
    // 24×24 视口几何等比放大到画布边长；线宽换算回画布 px 保持不变。
    final double scale = size.width / 24;
    if (scale <= 0) return;
    canvas.save();
    canvas.scale(scale);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth / scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (mode == RedrawnArrowMode.oldArrow) {
      final double e = erase.clamp(0.0, 1.0);
      if (e >= 1) {
        canvas.restore();
        return;
      }
      if (e <= 0) {
        canvas.drawPath(_oldArrow(), paint);
        canvas.restore();
        return;
      }
      // 自尾部擦除 + 前进给（箭头向前滑出）。
      final Path full = _oldArrow().shift(Offset(shiftPx * e / scale, 0));
      final PathMetrics metrics = full.computeMetrics(forceClosed: false);
      final double totalLen = metrics.fold<double>(0, (a, m) => a + m.length);
      double remaining = totalLen * (1 - e);
      for (final PathMetric metric in metrics) {
        if (remaining <= 0) break;
        final double shown = metric.length < remaining
            ? metric.length
            : remaining;
        remaining -= shown;
        canvas.drawPath(metric.extractPath(0, shown), paint);
      }
      canvas.restore();
      return;
    }
    // 新箭头：杆先、倒钩 lag 一拍（进度由调用方的窗口编排给）。
    final double shaftT = shaft.clamp(0.0, 1.0);
    final double barbT = barb.clamp(0.0, 1.0);
    if (shaftT <= 0 && barbT <= 0) {
      canvas.restore();
      return;
    }
    if (shaftT > 0) {
      final Path shaftPath = Path()
        ..moveTo(_shaftA.dx, _shaftA.dy)
        ..lineTo(_shaftB.dx, _shaftB.dy);
      canvas.drawPath(_partial(shaftPath.computeMetrics(), shaftT), paint);
    }
    if (barbT > 0) {
      final Path barbPath = Path()
        ..moveTo(_shaftB.dx, _shaftB.dy)
        ..lineTo(_barbUp.dx, _barbUp.dy)
        ..moveTo(_shaftB.dx, _shaftB.dy)
        ..lineTo(_barbDown.dx, _barbDown.dy);
      canvas.drawPath(_partial(barbPath.computeMetrics(), barbT), paint);
    }
    canvas.restore();
  }

  /// 按比例取 Path 前 k 段的部分（跨段余量并入下一段）。
  static Path _partial(PathMetrics metrics, double t) {
    final double totalLen = metrics.fold<double>(0, (a, m) => a + m.length);
    double remaining = totalLen * t;
    final Path out = Path();
    for (final PathMetric metric in metrics) {
      if (remaining <= 0) break;
      final double shown = metric.length < remaining
          ? metric.length
          : remaining;
      remaining -= shown;
      out.addPath(metric.extractPath(0, shown), Offset.zero);
    }
    return out;
  }

  @override
  bool shouldRepaint(RedrawnArrowPainter oldDelegate) =>
      oldDelegate.mode != mode ||
      oldDelegate.erase != erase ||
      oldDelegate.shiftPx != shiftPx ||
      oldDelegate.shaft != shaft ||
      oldDelegate.barb != barb ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// painter 的二选一角色：擦除中的旧箭头 / 重画中的新箭头。
enum RedrawnArrowMode { oldArrow, newArrow }
