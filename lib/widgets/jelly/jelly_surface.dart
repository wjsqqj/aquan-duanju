import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/soft_body/soft_ring.dart';
import '../../theme/app_tokens.dart';
import '../../theme/jelly_tokens.dart';

/// `JellySurface` 的外部控制句柄：消费方（如播放器手势 HUD）在自己的值变化时
/// 触发一次挤压脉冲，不必继承或复刻物理内核。
class JellySurfaceController {
  _JellySurfaceState? _state;

  /// 挤一下（strength 传形变比例，正压扁 / 负鼓起）。
  void squash(double strength) => _state?._pressImpulse(strength);
}

/// 果冻表面：软体物理驱动的形变 + "实心果冻"材质（渐变 / 反光 / 边缘高光）。
///
/// 设计要点（`design.md §13`）：
/// - 物理走 [SoftRing]（Verlet + 三重实测约束 + 面积守恒压力 + 回位系绳）；
/// - 静止形状是**超椭圆**，所以胶囊按钮不会塌成正圆；
/// - 自绘 painter 用 `repaint: ring` 订阅物理通知，**不每帧 setState**，
///   子树（图标/文字）不会跟着重建；
/// - 静止后自动停 ticker；`disableAnimations` 时完全不起 ticker；
/// - 默认**不**叠 `BackdropFilter`（背后通常是纯色，糊了也看不见还白付开销）。
class JellySurface extends StatefulWidget {
  const JellySurface({
    super.key,
    required this.size,
    this.child,
    this.preset = JellyPreset.snap,
    this.color,
    this.padding,
    this.onTap,
    this.tooltip,
    this.enabled = true,
    this.backdropBlur = false,
    this.blurSigma = 12,
    this.elevation = 14,
    this.exponent = 5,
    this.popOnMount = false,
    this.controller,
  });

  /// 软体静止形状的尺寸（胶囊取宽×高）。
  final Size size;

  /// 居中内容（图标 / 文字）。
  final Widget? child;

  final JellyPreset preset;

  /// 主色；`null` 取主题 `brand`。
  final Color? color;

  /// 内容内边距。
  final EdgeInsetsGeometry? padding;

  final VoidCallback? onTap;

  /// 悬浮提示，同时作为无障碍标签。
  final String? tooltip;

  final bool enabled;

  /// 是否在果冻背后叠一层模糊玻璃。
  ///
  /// **只有当背后确实有图/文时才值得打开**（纯色背景上完全看不出效果）。
  final bool backdropBlur;

  final double blurSigma;

  /// 外投影高度。
  final double elevation;

  /// 超椭圆指数：5 ≈ 圆角矩形，2 = 椭圆。
  final double exponent;

  /// 挂载时先压一下再回弹（选中态凝胶块出现时的「duang」）。
  /// `reduceMotion` 开启时不起 ticker，自然退化为静止形状。
  final bool popOnMount;

  /// 外部控制句柄；传了就在挂载时登记、销毁时注销。
  final JellySurfaceController? controller;

  @override
  State<JellySurface> createState() => _JellySurfaceState();
}

class _JellySurfaceState extends State<JellySurface>
    with SingleTickerProviderStateMixin {
  late SoftRing _ring;
  late Ticker _ticker;
  Duration _last = Duration.zero;
  bool _hovered = false;
  bool _ticking = false;

  Offset get _center => Offset(widget.size.width / 2, widget.size.height / 2);

  @override
  void initState() {
    super.initState();
    _ring = _createRing();
    _ticker = createTicker(_onTick);
    widget.controller?._state = this;
    // `initState` 里不能读继承组件（`_reduceMotion` 要查 MediaQuery），
    // 借 post-frame 推迟到首帧之后起弹。
    if (widget.popOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _kick();
      });
    }
  }

  SoftRing _createRing() {
    final ring = SoftRing(
      center: _center,
      radius: widget.size.shortestSide / 2,
      physics: widget.preset.physics,
    );
    ring.setPolygon(
      _center,
      SoftRing.superellipse(
        widget.size.width,
        widget.size.height,
        exponent: widget.exponent,
      ),
    );
    return ring;
  }

  @override
  void didUpdateWidget(covariant JellySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._state = null;
      widget.controller?._state = this;
    }
    if (oldWidget.size != widget.size ||
        oldWidget.exponent != widget.exponent) {
      _ring.dispose();
      _ring = _createRing();
      if (_ticking) {
        // 让 painter 立刻换到新环
        setState(() {});
      }
    }
    if (oldWidget.preset != widget.preset) {
      _ring.physics = widget.preset.physics;
      _kick();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「减少动效」时不跑物理：直接呈现静止形状（AC20）。
    if (_reduceMotion) {
      _stopTicker();
    }
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? const Duration(milliseconds: 16)
        : elapsed - _last;
    _last = elapsed;
    // 固定 1/120 步长，最多补 4 步，避免卡顿后跳帧
    final steps = (dt.inMicroseconds / 8333).clamp(1, 4).toInt();
    for (var i = 0; i < steps; i++) {
      _ring.step(1 / 120);
    }
    if (_ring.isSettled) _stopTicker();
  }

  void _ensureTicker() {
    if (_reduceMotion || _ticking) return;
    _last = Duration.zero;
    _ticker.start();
    _ticking = true;
  }

  void _stopTicker() {
    if (!_ticking) return;
    _ticker.stop();
    _ticking = false;
  }

  void _kick() {
    _ring.squash(0.06);
    _ensureTicker();
  }

  /// 按下：水平拉、垂直压（与 melon-lab 的 applyImpulse 同构）。
  void _press() {
    if (!widget.enabled) return;
    _ring.squash(0.14);
    _ensureTicker();
  }

  /// 松手：反向轻弹一下，制造回弹感。
  void _release() {
    if (!widget.enabled) return;
    _ring.squash(-0.05);
    _ensureTicker();
  }

  /// 外部脉冲入口（[JellySurfaceController] 用）：不做 enabled 拦截——
  /// HUD 这类「值变了就弹」的反馈不属于可点交互。
  void _pressImpulse(double strength) {
    _ring.squash(strength);
    _ensureTicker();
  }

  @override
  void dispose() {
    widget.controller?._state = null;
    _ticker.dispose();
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final Color base = widget.color ?? tokens.colors.brand;
    final JellyMaterial material = JellyMaterial.fromBase(base);

    Widget surface = SizedBox.fromSize(
      size: widget.size,
      child: Stack(
        children: <Widget>[
          // 可选：背后内容的模糊（仅在确有内容时打开）
          if (widget.backdropBlur)
            Positioned.fill(
              child: ClipPath(
                clipper: _RingClipper(_ring),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: widget.blurSigma,
                    sigmaY: widget.blurSigma,
                  ),
                  child: ColoredBox(color: base.withValues(alpha: 0.10)),
                ),
              ),
            ),
          Positioned.fill(
            child: CustomPaint(
              painter: _JellyPainter(
                ring: _ring,
                material: material,
                elevation: widget.elevation,
                hovered: _hovered,
                enabled: widget.enabled,
              ),
            ),
          ),
          if (widget.child != null)
            Positioned.fill(
              child: Padding(
                padding: widget.padding ?? EdgeInsets.zero,
                child: Center(child: widget.child),
              ),
            ),
        ],
      ),
    );

    surface = MouseRegion(
      cursor: widget.enabled && widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (!widget.enabled) return;
        setState(() => _hovered = true);
        _ensureTicker();
      },
      onExit: (_) {
        if (!mounted) return;
        setState(() => _hovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => _press(),
        onTapUp: widget.onTap == null ? null : (_) => _release(),
        onTapCancel: widget.onTap == null ? null : _release,
        onTap: widget.onTap,
        child: surface,
      ),
    );

    if (widget.tooltip != null) {
      surface = Tooltip(message: widget.tooltip!, child: surface);
    }
    return surface;
  }
}

class _RingClipper extends CustomClipper<Path> {
  _RingClipper(this.ring);

  final SoftRing ring;

  @override
  Path getClip(Size size) => ring.buildPath();

  @override
  bool shouldReclip(covariant _RingClipper oldClipper) => true;
}

/// 自绘果冻：外投影 → 竖向渐变本体 → 顶部反光 → 边缘高光。
///
/// `repaint: ring` 让物理每次 notify 时只重绘，不触发 widget 重建。
class _JellyPainter extends CustomPainter {
  _JellyPainter({
    required this.ring,
    required this.material,
    required this.elevation,
    required this.hovered,
    required this.enabled,
  }) : super(repaint: ring);

  final SoftRing ring;
  final JellyMaterial material;
  final double elevation;
  final bool hovered;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = ring.buildPath();
    final Rect bounds = path.getBounds();
    if (bounds.isEmpty) return;

    final double opacity = enabled ? 1.0 : 0.45;

    // 外投影：果冻"有厚度"的一半来源
    canvas.drawShadow(
      path,
      material.shadow.withValues(alpha: hovered ? 0.62 : 0.48),
      hovered ? elevation * 1.3 : elevation,
      false,
    );

    // 本体：上亮下暗的竖向渐变
    final Paint body = Paint()
      ..shader = ui.Gradient.linear(
        Offset(bounds.center.dx, bounds.top),
        Offset(bounds.center.dx, bounds.bottom),
        <Color>[material.light, material.base, material.dark],
        const <double>[0.0, 0.52, 1.0],
      );
    canvas.drawPath(path, _withOpacity(body, opacity));

    canvas.save();
    canvas.clipPath(path);

    // 顶部反光带：只在上面 45%，hover 时更亮
    final double glossTop = hovered ? 0.34 : 0.22;
    final Paint gloss = Paint()
      ..shader = ui.Gradient.linear(
        Offset(bounds.center.dx, bounds.top),
        Offset(bounds.center.dx, bounds.top + bounds.height * 0.5),
        <Color>[
          material.gloss.withValues(alpha: glossTop),
          material.gloss.withValues(alpha: 0),
        ],
        const <double>[0.0, 1.0],
      );
    canvas.drawRect(bounds, gloss);

    // 底部内阴影：压出"装着东西"的体积感
    final Paint innerShade = Paint()
      ..shader = ui.Gradient.linear(
        Offset(bounds.center.dx, bounds.bottom - bounds.height * 0.35),
        Offset(bounds.center.dx, bounds.bottom),
        <Color>[
          const Color(0x00000000),
          Colors.black.withValues(alpha: 0.16 * opacity),
        ],
        const <double>[0.0, 1.0],
      );
    canvas.drawRect(bounds, innerShade);

    canvas.restore();

    // 边缘高光：1px 亮边，让轮廓"立"起来
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = material.rim.withValues(alpha: material.rim.a * opacity),
    );
  }

  Paint _withOpacity(Paint paint, double opacity) {
    if (opacity >= 1) return paint;
    paint.color = paint.color.withValues(alpha: opacity);
    return paint;
  }

  @override
  bool shouldRepaint(covariant _JellyPainter oldDelegate) =>
      oldDelegate.hovered != hovered ||
      oldDelegate.enabled != enabled ||
      oldDelegate.elevation != elevation ||
      oldDelegate.material != material;
}
