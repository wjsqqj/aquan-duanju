import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'film_jitter.dart' show fxHash01;

/// 手绘圈注步进时钟：100ms 一跳（10fps，atlas scribble-ring 步进时钟
/// 出处；E4 design §5）。步进式（step-end）：帧内静止、帧间硬切，零 tween。
const Duration kScribbleTickPeriod = Duration(milliseconds: 100);

/// 画入/擦除步数：3 tick 渐显（35%/65%/88%）后第 4 tick 全显；擦除反向。
const int kScribbleDrawInTicks = 4;

/// Catmull-Rom 结点数（16 结点抖动基础椭圆）。
const int kScribbleNodes = 16;

/// 沸腾抖动幅度：每结点半径 ±3.2px（atlas scribble-ring 同值）。
const double kScribbleJitterPx = 3.2;

/// 圈注外扩比例：环比目标大 1.18 倍（atlas scribble-ring fit 同值）。
const double kScribbleRingFit = 1.18;

/// 环心偏移（相对目标尺寸的比例；atlas scribble-ring offset——笔迹重心
/// 微微上提偏右，不压正中，更像手画的圈）。
const double kScribbleCenterShiftDx = 0.02;
const double kScribbleCenterShiftDy = -0.03;

/// 不闭合弧：扫过整圆的 74%（atlas 同值），留出缺口才是「圈注」不是「外框」。
const double kScribbleSweep = 0.74;

/// 起笔角（度，从 -130° 即左上起，顺时针扫）。
const double kScribbleStartDegrees = -130.0;

/// 笔迹墨色透明度（brand @0.55，design §5；色相一律取 `colors.brand`）。
const double kScribbleInkAlpha = 0.55;

/// 变宽笔迹宽度表（16 档，占椭圆**短半径**的比例）：起笔钝 35% →
/// 收笔细 8%（design §5 变宽笔迹；sm 徽标短半径 ≈12px → 起笔 ≈4px、
/// 收笔 ≈1px，是马克笔手写的粗细关系）。
const List<double> kScribbleWidthTable = <double>[
  0.35, 0.32, 0.28, 0.25, 0.23, 0.21, //
  0.195, 0.18, 0.165, 0.15, 0.14, 0.13, //
  0.12, 0.105, 0.09, 0.08,
];

/// 每段样条的采样密度（画轮廓折线用；6×15+1 = 91 采样点，肉眼即平滑）。
const int kScribbleSamplesPerSegment = 6;

/// 画入/擦除的可见度曲线（design §5 公式 `1-(1-k/4)^1.5`）：
/// tick 0→0，1→0.35，2→0.65，3→0.88，≥4→1（保持期每 tick 重随机沸腾）。
@visibleForTesting
double fxScribbleVisibility(int tick) {
  if (tick <= 0) return 0;
  if (tick >= kScribbleDrawInTicks) return 1;
  final double k = tick / kScribbleDrawInTicks;
  return 1.0 - math.pow(1.0 - k, 1.5).toDouble();
}

/// 圈注基础椭圆的 16 个结点（含确定性沸腾抖动）：结点 j 落在
/// 起笔角起、74% 扫角的椭圆上，半径按 [fxHash01](j, tick) ±3.2px 抖动。
/// 同 (size, tick) 必同结点——沸腾步进可复现。
@visibleForTesting
List<Offset> fxScribbleNodes(Size size, int tick) {
  final Offset center =
      size.center(Offset.zero) +
      Offset(
        size.width * kScribbleCenterShiftDx,
        size.height * kScribbleCenterShiftDy,
      );
  final double rx = size.width * kScribbleRingFit / 2;
  final double ry = size.height * kScribbleRingFit / 2;
  final double start = kScribbleStartDegrees * math.pi / 180;
  final double sweep = kScribbleSweep * 2 * math.pi;
  return <Offset>[
    for (int j = 0; j < kScribbleNodes; j++)
      () {
        final double theta = start + sweep * j / (kScribbleNodes - 1);
        final double dj = (fxHash01(j, tick) * 2 - 1) * kScribbleJitterPx;
        return center +
            Offset((rx + dj) * math.cos(theta), (ry + dj) * math.sin(theta));
      }(),
  ];
}

/// 变宽笔迹轮廓（填充 Path）：Catmull-Rom 样条过 16 结点，按
/// [visibility] 截取画入进度，宽度表逐采样变宽，法向两侧偏移成
/// ribbon 多边形（起笔平头=钝、收笔尖细）。visibility<=0 返回空 Path。
@visibleForTesting
Path fxScribbleRibbon(Size size, int tick, double visibility) {
  final Path path = Path();
  if (visibility <= 0 || size.isEmpty) return path;
  final List<Offset> nodes = fxScribbleNodes(size, tick);
  final int n = nodes.length;
  final int totalSamples = (n - 1) * kScribbleSamplesPerSegment + 1;
  final int count = ((totalSamples * visibility).round()).clamp(
    2,
    totalSamples,
  );

  // 结点切线（uniform Catmull-Rom，开放链端点重复首尾结点）。
  Offset tangentAtNode(int k) =>
      (nodes[k + 1 >= n ? n - 1 : k + 1] - nodes[k - 1 < 0 ? 0 : k - 1]) / 2;

  Offset splineAt(double u) {
    final double scaled = (u * (n - 1)).clamp(0.0, (n - 1).toDouble());
    final int j = scaled.floor().clamp(0, n - 2);
    final double tau = scaled - j;
    final Offset m0 = tangentAtNode(j);
    final Offset m1 = tangentAtNode(j + 1);
    final Offset p0 = nodes[j];
    final Offset p1 = nodes[j + 1];
    final double t2 = tau * tau;
    final double t3 = t2 * tau;
    final double h00 = 2 * t3 - 3 * t2 + 1;
    final double h10 = t3 - 2 * t2 + tau;
    final double h01 = -2 * t3 + 3 * t2;
    final double h11 = t3 - t2;
    return p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11;
  }

  Offset tangentAt(double u) {
    final double scaled = (u * (n - 1)).clamp(0.0, (n - 1).toDouble());
    final int j = scaled.floor().clamp(0, n - 2);
    final double tau = scaled - j;
    final Offset m0 = tangentAtNode(j);
    final Offset m1 = tangentAtNode(j + 1);
    final Offset p0 = nodes[j];
    final Offset p1 = nodes[j + 1];
    final double t2 = tau * tau;
    final double d00 = 6 * t2 - 6 * tau;
    final double d10 = 3 * t2 - 4 * tau + 1;
    final double d01 = -6 * t2 + 6 * tau;
    final double d11 = 3 * t2 - 2 * tau;
    return p0 * d00 + m0 * d10 + p1 * d01 + m1 * d11;
  }

  // 短半径标尺的宽度表插值（结点位次 → 采样位次线性插值）。
  final double rShort = math.min(
    size.width * kScribbleRingFit / 2,
    size.height * kScribbleRingFit / 2,
  );
  double widthAt(double u) {
    final double scaled = (u * (n - 1)).clamp(0.0, (n - 1).toDouble());
    final int j = scaled.floor().clamp(0, n - 2);
    final double frac = scaled - j;
    final double w0 = kScribbleWidthTable[j];
    final double w1 = kScribbleWidthTable[j + 1];
    return (w0 + (w1 - w0) * frac) * rShort;
  }

  final List<Offset> lefts = <Offset>[];
  final List<Offset> rights = <Offset>[];
  for (int i = 0; i < count; i++) {
    final double u = i / (totalSamples - 1);
    final Offset p = splineAt(u);
    Offset d = tangentAt(u);
    final double len = d.distance;
    d = len <= 0 ? const Offset(1, 0) : d / len;
    // 法向（左手侧）：(-ty, tx)。
    final Offset normal = Offset(-d.dy, d.dx);
    final double half = widthAt(u) / 2;
    lefts.add(p + normal * half);
    rights.add(p - normal * half);
  }

  path.moveTo(lefts.first.dx, lefts.first.dy);
  for (final Offset p in lefts.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  for (int i = rights.length - 1; i >= 0; i--) {
    path.lineTo(rights[i].dx, rights[i].dy);
  }
  path.close();
  return path;
}

/// 手绘圈注（effect-atlas scribble-ring 移植 · E4）。
///
/// [show] = true 时在 [child]（目标，如封面徽标）上叠一层不闭合手绘
/// 圈注：10fps 步进时钟驱动「沸腾」——每 tick 重随机 16 结点半径
/// （确定性 hash，零 tween），画入 3 tick 渐显后保持沸腾；[show] 翻
/// false 逐 tick 擦除，擦完停钟。**时钟只在 show/擦除期间运行**——非
/// hover 期零开销。
///
/// 层结构：`Stack > child + Positioned.fill(CustomPaint)`——painter 在
/// child 尺寸画布上按外扩 1.18 绘制（canvas 不裁剪，可越界画出圈），
/// 不进封面遮罩，不触 series_card 的渐变断言。
///
/// 门控（AC20）：由消费方（SeriesCard 桌面 hover 接线）保证只在桌面
/// 非 reduceMotion 场景挂载本件；移动/TV/reduceMotion 不构建。
class FxScribbleBadge extends StatefulWidget {
  const FxScribbleBadge({super.key, required this.show, required this.child});

  /// true = 起画（画入→保持沸腾）；false = 擦除→停钟直通 child。
  final bool show;

  /// 被圈注的目标。
  final Widget child;

  @override
  State<FxScribbleBadge> createState() => _FxScribbleBadgeState();
}

class _FxScribbleBadgeState extends State<FxScribbleBadge> {
  Timer? _timer;
  int _tick = 0;
  bool _erasing = false;

  bool get _active => _timer != null;

  @override
  void initState() {
    super.initState();
    if (widget.show) _startBoil();
  }

  @override
  void didUpdateWidget(covariant FxScribbleBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.show == oldWidget.show) return;
    if (widget.show) {
      _startBoil();
    } else if (_timer != null) {
      // 擦除：从当前可见度反向走（保持期从全显起，擦 4 tick ≈400ms）。
      _erasing = true;
      _tick = _tick.clamp(0, kScribbleDrawInTicks);
    }
  }

  void _startBoil() {
    _erasing = false;
    _tick = 0;
    _timer ??= Timer.periodic(kScribbleTickPeriod, _onTick);
  }

  void _onTick(Timer timer) {
    if (!mounted) {
      timer.cancel();
      return;
    }
    if (_erasing) {
      if (_tick <= 0) {
        // 擦完：停钟直通 child（非 hover 期零开销）。
        _timer?.cancel();
        _timer = null;
        _erasing = false;
        setState(() {});
        return;
      }
      _tick--;
    } else {
      // 保持期继续沸腾（visibility 封顶 1，tick 递增换取新随机相位）。
      _tick++;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return widget.child;
    final Color ink = context.app.colors.brand.withValues(
      alpha: kScribbleInkAlpha,
    );
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: ScribbleRingPainter(
                tick: _tick,
                visibility: fxScribbleVisibility(_tick),
                color: ink,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // ---- 测试口（test/motion/scribble_ring_test.dart）----

  @visibleForTesting
  bool get debugTicking => _timer != null;

  @visibleForTesting
  bool get debugErasing => _erasing;

  @visibleForTesting
  int get debugTick => _tick;
}

/// 圈注笔迹 painter：几何全在 [fxScribbleRibbon]（纯函数，可独立测）。
class ScribbleRingPainter extends CustomPainter {
  ScribbleRingPainter({
    required this.tick,
    required this.visibility,
    required this.color,
  });

  /// 沸腾步号（每 tick 重随机结点半径）。
  final int tick;

  /// 画入/擦除可见度（0..1，截取扫弧进度）。
  final double visibility;

  /// 笔迹色（brand @0.55，由调用方从 Token 取）。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (visibility <= 0) return;
    final Path path = fxScribbleRibbon(size, tick, visibility);
    if (path.getBounds().isEmpty) return;
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  // 契约（E3 沉淀）：比较全部影响绘制的入参。
  @override
  bool shouldRepaint(ScribbleRingPainter oldDelegate) =>
      oldDelegate.tick != tick ||
      oldDelegate.visibility != visibility ||
      oldDelegate.color != color;
}
