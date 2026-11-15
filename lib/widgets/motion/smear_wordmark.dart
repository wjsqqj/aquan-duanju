import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';

/// atlas smear-trail-preloader 的 sweep 时长：1650ms（规格注释
/// `sweep 1650（800..4000）`——整行甩入的完整拍）。kit 编排常量
/// （DESIGN.md §6 编排豁免，atlas 出处）。
const Duration fxSmearSweep = Duration(milliseconds: 1650);

/// 短行 clamp 档：品牌标语这类 ≤6 字的行 clamp 到 1100ms 保轻快
/// （design §3「本场景文案 4 字 → clamp 到 ~1100ms」）。
const Duration fxSmearSweepCompact = Duration(milliseconds: 1100);

/// 歪斜五次幂缓动的转折点 K=0.38（atlas 规格注释「K=0.38 转折」）。
const double fxSmearSkewK = 0.38;

/// 字符级错拍：58ms（atlas 行错拍 `index×58ms` 直译到字——单行标语
/// 没有行可错，错拍落在字符上，从左逐字起跑）。
const Duration fxSmearCharStagger = Duration(milliseconds: 58);

/// 首字符残影：22 枚副本、回看 560ms（atlas「首字母 22 枚章回看 560ms」，
/// trail=560）。
const int fxSmearHeadGhosts = 22;
const Duration fxSmearHeadLookback = Duration(milliseconds: 560);

/// 尾字符残影：36 枚副本、回看 800ms（atlas「尾字母 36 枚回看 800ms」）。
const int fxSmearTailGhosts = 36;
const Duration fxSmearTailLookback = Duration(milliseconds: 800);

/// 残影聚拢指数 1.7：副本 i 位于 主位 − gap·(i/n)^1.7——小 i 贴字母聚拢
/// （atlas「章 i 位于 x−gap×(i/n)^1.7（贴字母处聚拢）」）。
const double fxSmearGhostGather = 1.7;

/// 残影衰减指数 1.5：alpha = base·(1−i/n)^1.5（atlas 同式直译）。
const double fxSmearGhostFade = 1.5;

/// 残影基准 alpha（atlas `alpha=base×(1−i/n)^1.5` 的 base；atlas 未给值，
/// 本库按品牌页轻拖影取 0.30——视觉判定）。
const double fxSmearGhostAlpha = 0.30;

/// 甩入行程系数：每字从左甩入的行程 = 字符推进宽 × 1.5（atlas 用位置偏移
/// 表调多行布局，单行标语取字符宽倍数为等效量——视觉判定，非 atlas 数）。
const double fxSmearTravelFactor = 1.5;

/// 主层 alpha 淡入窗：字符窗口前 20% 内完成（design §3「主层 alpha 逐字
/// 按窗口起」——窗口占比为视觉判定）。
const double fxSmearAlphaWindow = 0.2;

/// 残影消隐阈：gap 收拢到亚像素（0.75px）以下即不再画——落定时残影「缩回」
/// 消失而不是叠在主字下面加深笔画。
const double fxSmearGhostMinGapPx = 0.75;

/// 歪斜五次幂缓动（atlas smear-trail-preloader 纯函数直译）。
///
/// 分段幂函数，K=[fxSmearSkewK] 转折且连续（含一阶导）：
/// - 前段 t<K：`K·(t/K)^5`（规格「前段 (t/K)^5」；乘 K 归一到分段终点连续）
///   ——开局贴地慢爬、段末速度拉满；
/// - 后段 t≥K：`K + (1−K)·(1 − ((1−t)/(1−K))^5)` —— 猛窜出（硬启动）后
///   长着陆，五次幂长尾减速滑进家位。
///
/// 两段在 t=K 处取值同为 K、一阶导同为 5，全程单调（0→1）无跳变。
@visibleForTesting
double fxSmearSkewEase(double t) {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  final double k = fxSmearSkewK;
  if (t < k) {
    final double u = t / k;
    return k * u * u * u * u * u;
  }
  final double u = (t - k) / (1 - k);
  final double rem = 1 - u;
  return k + (1 - k) * (1 - rem * rem * rem * rem * rem);
}

/// 副本 j 的聚拢偏移比：(j/n)^1.7（atlas 贴字母处聚拢）。
@visibleForTesting
double fxSmearGhostOffsetRatio(int j, int n) =>
    n <= 0 ? 0 : math.pow(j / n, fxSmearGhostGather).toDouble();

/// 副本 j 的 alpha：base·(1−j/n)^1.5（atlas 同式直译）。
@visibleForTesting
double fxSmearGhostAlphaAt(int j, int n) => n <= 0
    ? 0
    : fxSmearGhostAlpha * math.pow(1 - j / n, fxSmearGhostFade).toDouble();

/// 品牌标语拖影甩入（effect-atlas smear-trail-preloader 移植 · E7）。
///
/// 逐字从左甩入：字符 i 在 `i×[fxSmearCharStagger]` 起跑、共享时钟同时落定
/// （总长见 [_sweepFor]），位移由 [fxSmearSkewEase] 驱动（开局慢爬 → 硬启动
/// → 长着陆）；首/尾字符身后拖一串自身残影副本（[fxSmearHeadGhosts] /
/// [fxSmearTailGhosts] 枚，位置与 alpha 见 kit 常量注释），副本位置由「回看
/// 窗口」给出：gap = 行程 × (p(t) − p(t−lookback))，纯时间函数——着陆后
/// p 恒定 → gap 收拢为 0 → 残影缩回消失（atlas「着陆时回看窗口收拢→残影
/// 缩回」）。
///
/// 落定后切普通 `Text`：外框尺寸取全文 TextPainter 实测（单行），动效期与
/// 落定期外框一致，切换无布局跳动；中文等宽场景逐字前缀和 = 整形推进。
///
/// 文本变更不重播（启动页一次性）；`style` 必须带 color（残影 alpha 需烘焙
/// 进字形颜色）。
///
/// 门控（AC20）：「减少动效」静态直出（不装 controller，直接普通 Text）。
class FxSmearWordmark extends StatefulWidget {
  const FxSmearWordmark({super.key, required this.text, required this.style});

  /// 标语文本（单行）。
  final String text;

  /// 标语样式（须含 color）。
  final TextStyle style;

  @override
  State<FxSmearWordmark> createState() => _FxSmearWordmarkState();
}

class _FxSmearWordmarkState extends State<FxSmearWordmark>
    with SingleTickerProviderStateMixin {
  /// null = 直出形态（reduceMotion）：不装控制器。
  AnimationController? _controller;

  bool _wired = false;
  bool _done = false;

  /// 实测布局（全文外框 + 逐字推进 + 家位表）。
  _SmearLayout? _layout;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measure();
    if (_wired) return;
    _wired = true;
    // 门控（AC20）：「减少动效」静态直出，不装 controller。
    if (AppMetrics.reduceMotionEnabled(context)) return;
    final _SmearLayout layout = _layout!;
    _controller = AnimationController(
      vsync: this,
      duration: _sweepFor(layout.chars.length),
    )..addStatusListener(_onStatus);
    _controller!.forward();
  }

  @override
  void didUpdateWidget(covariant FxSmearWordmark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _measure();
      // 文本变更不重播（启动页一次性）；飞行中换文本只重算布局表，
      // controller 继续走（边界场景，品牌页实际不会发生）。
    }
  }

  @override
  void dispose() {
    _controller?.removeStatusListener(_onStatus);
    _controller?.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _done = true);
    }
  }

  /// 短行 clamp：≤6 字走轻快档（design §3），长行用 atlas 原值。
  static Duration _sweepFor(int charCount) =>
      charCount <= 6 ? fxSmearSweepCompact : fxSmearSweep;

  void _measure() {
    // 与落定期 Text 的整形样式逐位一致：Text(inherit 默认 true) 会与
    // DefaultTextStyle 合并（如主题字距 0.5 被继承）——动效期测量与残影
    // 烘焙必须用同一份合并样式，否则落定切换会跳 1px 级宽度。
    final TextStyle style = widget.style.inherit
        ? DefaultTextStyle.of(context).style.merge(widget.style)
        : widget.style;
    assert(style.color != null, '标语样式必须带 color（残影 alpha 烘焙进颜色）');
    final TextDirection direction = Directionality.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    // 全文一次实测 → 外框尺寸（与落定普通 Text 一致，切换零跳动）。
    final TextPainter full = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final Size box = Size(full.width, full.height);
    full.dispose();
    // 逐字推进量 → 家位前缀和（同样式同 scaler，单行）。
    final List<String> chars = widget.text.characters.toList(growable: false);
    final List<double> advances = <double>[];
    double cursor = 0;
    final List<double> homeX = <double>[];
    for (final String char in chars) {
      final TextPainter tp = TextPainter(
        text: TextSpan(text: char, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double advance = tp.width;
      tp.dispose();
      advances.add(advance);
      homeX.add(cursor);
      cursor += advance;
    }
    setState(() {
      _layout = _SmearLayout(
        chars: chars,
        style: style,
        color: style.color!,
        textDirection: direction,
        textScaler: scaler,
        box: box,
        advances: advances,
        homeX: homeX,
        sweep: _sweepFor(chars.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final _SmearLayout? layout = _layout;
    final AnimationController? controller = _controller;
    if (controller == null || _done || layout == null) {
      // 静态直出（reduceMotion / 已落定稳态）：普通 Text。
      return Text(widget.text, style: widget.style, maxLines: 1);
    }
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return SizedBox.fromSize(
            size: layout.box,
            child: CustomPaint(
              size: layout.box,
              painter: _SmearPainter(
                progress: controller.value,
                layout: layout,
              ),
            ),
          );
        },
      ),
    );
  }

  // ---- 测试口（test/motion/smear_wordmark_test.dart）----

  @visibleForTesting
  bool get debugAnimated => _controller != null && !_done;

  @visibleForTesting
  double get debugProgress => _controller?.value ?? 1;
}

/// 一次实测的布局快照（painter 全部绘制入参的唯一来源）。
class _SmearLayout {
  const _SmearLayout({
    required this.chars,
    required this.style,
    required this.color,
    required this.textDirection,
    required this.textScaler,
    required this.box,
    required this.advances,
    required this.homeX,
    required this.sweep,
  });

  final List<String> chars;
  final TextStyle style;
  final Color color;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final Size box;
  final List<double> advances;
  final List<double> homeX;
  final Duration sweep;
}

class _SmearPainter extends CustomPainter {
  _SmearPainter({required this.progress, required this.layout});

  /// 共享时钟进度（controller.value 0..1）。
  final double progress;

  final _SmearLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final double elapsedMs = progress * layout.sweep.inMilliseconds;
    // 层序：残影垫底（首/尾两条副本链），主字压顶（atlas 同构）。
    _paintChain(
      canvas,
      0,
      fxSmearHeadGhosts,
      fxSmearHeadLookback.inMilliseconds.toDouble(),
      elapsedMs,
    );
    final int last = layout.chars.length - 1;
    if (last > 0) {
      _paintChain(
        canvas,
        last,
        fxSmearTailGhosts,
        fxSmearTailLookback.inMilliseconds.toDouble(),
        elapsedMs,
      );
    }
    for (int i = 0; i < layout.chars.length; i++) {
      _paintMain(canvas, i, elapsedMs);
    }
  }

  /// 字符 i 在 [elapsedMs] 的姿态：(进度 p, 主层 alpha)。共享时钟同时落定：
  /// 窗口 = [i×stagger, sweep]，窗口内线性时间过 [fxSmearSkewEase]。
  (double, double) _pose(int i, double elapsedMs) {
    final double startMs = fxSmearCharStagger.inMilliseconds * i.toDouble();
    final double windowMs = layout.sweep.inMilliseconds - startMs;
    if (elapsedMs <= startMs) return (0, 0);
    if (windowMs <= 0) return (1, 1);
    final double u = ((elapsedMs - startMs) / windowMs).clamp(0.0, 1.0);
    final double p = fxSmearSkewEase(u);
    final double alpha =
        ((elapsedMs - startMs) / (windowMs * fxSmearAlphaWindow)).clamp(
          0.0,
          1.0,
        );
    return (p, alpha);
  }

  /// 字符 i 在任意时刻（含回看负时刻）的进度；未起跑 = 0。
  double _progressAt(int i, double elapsedMs) {
    if (elapsedMs <= 0) return 0.0;
    final (double p, _) = _pose(i, elapsedMs);
    return p;
  }

  /// 甩入行程：字符自身推进宽 × [fxSmearTravelFactor]。
  double _travel(int i) => layout.advances[i] * fxSmearTravelFactor;

  void _paintMain(Canvas canvas, int i, double elapsedMs) {
    final (double p, double alpha) = _pose(i, elapsedMs);
    if (alpha <= 0) return;
    final TextPainter tp = _glyph(
      layout.chars[i],
      layout.color.withValues(alpha: alpha),
    );
    final double x = layout.homeX[i] - _travel(i) * (1 - p);
    tp.paint(canvas, Offset(x, 0));
    tp.dispose();
  }

  /// 首/尾字符的残影副本链：gap = 行程 × (p(t) − p(t−lookback))——回看窗口
  /// 内走过的路程；着陆后 p 恒定 → gap=0 → 亚像素收拢即消隐（缩回）。
  void _paintChain(
    Canvas canvas,
    int charIndex,
    int ghostCount,
    double lookbackMs,
    double elapsedMs,
  ) {
    final (double pNow, double mainAlpha) = _pose(charIndex, elapsedMs);
    if (mainAlpha <= 0) return;
    final double travel = _travel(charIndex);
    final double pThen = _progressAt(charIndex, elapsedMs - lookbackMs);
    final double gap = travel * math.max(0.0, pNow - pThen);
    if (gap < fxSmearGhostMinGapPx) return;
    final double xMain = layout.homeX[charIndex] - travel * (1 - pNow);
    // 远端（j 大）先画、近端后画、主字最顶——副本贴字母聚拢的遮挡语义。
    for (int j = ghostCount; j >= 1; j--) {
      final double alpha = fxSmearGhostAlphaAt(j, ghostCount) * mainAlpha;
      // 低于 alpha 量化步（1/255）的副本无视觉贡献，跳过省绘制。
      if (alpha <= 1 / 255) continue;
      final double x = xMain - gap * fxSmearGhostOffsetRatio(j, ghostCount);
      final TextPainter tp = _glyph(
        layout.chars[charIndex],
        layout.color.withValues(alpha: alpha),
      );
      tp.paint(canvas, Offset(x, 0));
      tp.dispose();
    }
  }

  /// 单字 TextPainter（alpha 烘焙进颜色——drawParagraph 无逐笔画 alpha 口）。
  /// textScaler 必须与 [_measure] 的实测口径一致，否则系统字号缩放下
  /// 字形比家位槽窄、残影/主字错位。
  TextPainter _glyph(String char, Color color) {
    return TextPainter(
      text: TextSpan(
        text: char,
        style: layout.style.copyWith(color: color),
      ),
      textDirection: layout.textDirection,
      textScaler: layout.textScaler,
      maxLines: 1,
    )..layout();
  }

  @override
  bool shouldRepaint(_SmearPainter old) =>
      // 全部绘制入参都派生自 progress 与 layout（快照对象整体替换），二者
      // 覆盖样式/文本/尺寸/方向变更（E3 沉淀：shouldRepaint 必须比较全部
      // 影响绘制的入参）。
      old.progress != progress || !identical(old.layout, layout);
}
