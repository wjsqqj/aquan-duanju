import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../common.dart';
import 'fx_curves.dart';
import 'glyph_metrics.dart';

// =============================================================================
// 开书序幕（effect-atlas cut-line-preloader 移植 · E6）
//
// 编排豁免序列（DESIGN.md §6）：单序列总长 2120ms ≤ 2.4s cap，reduceMotion
// 直跳终态（这里是「完全不播」——仪式层立即让位，阅读器直进）。常规 UI
// 动画仍锁五档。
//
// 加载语义红线（NEVER DO #7）：本层不承载「加载中」文案/形态——正文照常
// 在层下加载，揭示后内容未就绪自然露出阅读器既有加载态。数字条滚落的是
// 章节号（无进度直开落第 1 章；目录跳章进未读书则落所点章），不是 0→100
// 进度——章节号语义对短剧/小说更自然，也回避了「进度=加载」的歧义。
// =============================================================================

/// 计数与剪切同步窗（atlas cut-line-preloader：数字条滚动与剪刀推进同一条
/// 时间线，1300ms）。kit 级 dartdoc 常量，挂编排豁免（不另占五档）。
const Duration fxCutCountWindow = Duration(milliseconds: 1300);

/// 剪到头后刀片张开拍（atlas 规格 80ms）。
const Duration fxCutBladeOpen = Duration(milliseconds: 80);

/// 刀片合拢拍（atlas 规格 90ms，合拢即「剪断」定音）。
const Duration fxCutBladeClose = Duration(milliseconds: 90);

/// 揭示延后拍（合拢后 90ms 才开始折叠，给剪断动作留视觉余韵）。
const Duration fxCutRevealGap = Duration(milliseconds: 90);

/// 两半封面折叠消失拍（atlas 规格 560ms，[Fx.fold] 曲线）。
const Duration fxCutRevealFold = Duration(milliseconds: 560);

/// 虚线/剪刀/计数条的退场淡出拍（与折叠窗同起点，120ms 先走完）。
const Duration fxCutInkFade = Duration(milliseconds: 120);

/// 序幕总长：1300 + 80 + 90 + 90 + 560 = 2120ms（≤2.4s 豁免 cap）。
Duration get fxCutTotal =>
    fxCutCountWindow +
    fxCutBladeOpen +
    fxCutBladeClose +
    fxCutRevealGap +
    fxCutRevealFold;

/// 封面上下分割比例（atlas 规格 55/45：上半占 55%）。
const double _kSplitFactor = 0.55;

/// 剪刀沿裁剪线滑动的起止边距（相对屏宽的比例，两侧各收 18%）。
const double _kScissorInset = 0.18;

/// 刀片张开半角（弧度）。剪切中在这档附近小幅开合，剪完后 80ms 张到这档。
const double _kBladeOpen = 0.62;

/// 剪切窗结束时的收拢角（弧度），张开拍从这里张回全开。
const double _kBladeSnipEnd = 0.30;

/// 刀片合拢半角（弧度）——两刃几乎贴合即「剪断」。
const double _kBladeClosed = 0.05;

/// 无进度首开的开书序幕（E6）。
///
/// 全屏仪式层：整屏封面被虚线剪裁线横向剪开（剪刀沿线推进，三位数字条
/// 同步滚落章节号），剪断后上下两半向各自边折叠消失（55/45 分割）露出
/// 阅读器。任何点按 = 立即跳到揭示窗起点（可跳过是硬要求）；「减少动效」
/// 开启时完全不播（onRevealed 直发，阅读器直进）。
///
/// 调用方契约：把本层叠在阅读器内容之上，[onRevealed] 里摘除本层——
/// 揭示时正文若尚未就绪，露出的是阅读器既有加载态（本层不替代它）。
class FxOpenBookRite extends StatefulWidget {
  const FxOpenBookRite({
    super.key,
    required this.coverUrl,
    required this.chapterNumber,
    required this.chapterTotal,
    required this.onRevealed,
  });

  /// 该书封面（走既有 CoverImage 口，不裸用 Image.network）。
  final String coverUrl;

  /// 落定的章节号（1 起）。无进度直开恒为 1；跳章进未读书为所点章。
  final int chapterNumber;

  /// 总章数（数字条旁的「共 N 章」）。
  final int chapterTotal;

  /// 揭示完成（或被 reduceMotion 直跳）后回调；调用方据此摘除仪式层。
  final VoidCallback onRevealed;

  @override
  State<FxOpenBookRite> createState() => _FxOpenBookRiteState();
}

class _FxOpenBookRiteState extends State<FxOpenBookRite>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: fxCutTotal,
  );

  Duration get _revealStart =>
      fxCutCountWindow + fxCutBladeOpen + fxCutBladeClose + fxCutRevealGap;

  /// 各段窗口（相对总长的线性 Interval）。
  late final Interval _countWindow = _window(Duration.zero, fxCutCountWindow);
  late final Interval _bladeOpenWindow = _window(
    fxCutCountWindow,
    fxCutCountWindow + fxCutBladeOpen,
  );
  late final Interval _bladeCloseWindow = _window(
    fxCutCountWindow + fxCutBladeOpen,
    fxCutCountWindow + fxCutBladeOpen + fxCutBladeClose,
  );
  late final Interval _revealWindow = _window(
    _revealStart,
    _revealStart + fxCutRevealFold,
  );
  late final Interval _inkWindow = _window(
    _revealStart,
    _revealStart + fxCutInkFade,
  );

  Interval _window(Duration from, Duration to) {
    final int total = fxCutTotal.inMilliseconds;
    return Interval(from.inMilliseconds / total, to.inMilliseconds / total);
  }

  /// 揭示窗起点的控制器刻度（点按跳过的落点）。
  double get _revealStartT =>
      _revealStart.inMilliseconds / fxCutTotal.inMilliseconds;

  /// onRevealed 只发一次；一律 post-frame 派发（reduceMotion 直跳路径会在
  /// build 相位内同步触发 completed，调用方 setState 撞 assert 的坑见
  /// fx-motion-contract「TweenAnimationBuilder 零时长 onEnd」条）。
  bool _announced = false;
  bool _wired = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    if (AppMetrics.reduceMotionEnabled(context)) {
      // reduceMotion：完全不播（直进阅读器）。value=1 触发 completed
      // 状态，_onStatus 里 post-frame 发 onRevealed。
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _announce();
  }

  void _announce() {
    if (_announced) return;
    _announced = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onRevealed();
    });
  }

  /// 点按跳过：跳到揭示窗起点（可跳过是硬要求——仪式不能绑架入口）。
  ///
  /// `set value` 会先 stop 掉进行中的动画，所以跳完要重新 forward——
  /// 剩余段按控制器值的相对节奏继续（forward() 从当前值续跑）。
  void _skip() {
    if (_controller.isCompleted) return;
    setState(() => _controller.value = _revealStartT);
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final AppTokens tokens = context.app;
        final AppMetrics m = tokens.metrics;
        final double t = _controller.value;

        // 分段派生：剪切进度 / 折叠进度 / 线稿淡出 / 刀片半角。
        final double cutT = Fx.cut.transform(_countWindow.transform(t));
        final double foldT = Fx.fold.transform(_revealWindow.transform(t));
        final double inkT = 1.0 - _inkWindow.transform(t);
        final double bladeTheta = _bladeTheta(t, cutT);
        final double foldScale = (1.0 - foldT).clamp(0.0, 1.0);

        return Semantics(
          label:
              '翻开${widget.chapterTotal > 0 ? ' 第${widget.chapterNumber}章' : ''}',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _skip,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double height = constraints.maxHeight;
                final double width = constraints.maxWidth;
                final double splitY = height * _kSplitFactor;
                return Stack(
                  children: [
                    // 上半封面（0..55%）：折叠 = 内容向自己那条边（顶边）scale→0。
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: splitY,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minWidth: width,
                          maxWidth: width,
                          minHeight: height,
                          maxHeight: height,
                          child: Transform.scale(
                            scale: foldScale,
                            alignment: Alignment.topCenter,
                            child: SizedBox.expand(
                              child: CoverImage(
                                url: widget.coverUrl,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 下半封面（55%..100%）：向底边折叠。
                    Positioned(
                      left: 0,
                      right: 0,
                      top: splitY,
                      bottom: 0,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.bottomCenter,
                          minWidth: width,
                          maxWidth: width,
                          minHeight: height,
                          maxHeight: height,
                          child: Transform.scale(
                            scale: foldScale,
                            alignment: Alignment.bottomCenter,
                            child: SizedBox.expand(
                              child: CoverImage(
                                url: widget.coverUrl,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 虚线剪裁线 + 剪刀（线稿层，揭示起 120ms 淡出）。
                    if (inkT > 0)
                      Positioned.fill(
                        child: Opacity(
                          opacity: inkT.clamp(0.0, 1.0),
                          child: CustomPaint(
                            painter: _CutLinePainter(
                              inkColor: tokens.colors.textPrimary,
                              splitY: splitY,
                              cutT: cutT,
                              bladeTheta: bladeTheta,
                            ),
                          ),
                        ),
                      ),
                    // 计数条 + 章节标签：实色托底保证可读（压在下半封面上）。
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: math.max(m.s24, height * 0.06),
                      child: Opacity(
                        opacity: inkT.clamp(0.0, 1.0),
                        child: _CounterBar(
                          value: _counterValue(t),
                          digitStyle: tokens.numbers.copyWith(
                            color: tokens.colors.textPrimary,
                          ),
                          labelStyle: tokens.label.copyWith(
                            color: tokens.colors.textSecondary,
                          ),
                          chapterNumber: widget.chapterNumber,
                          chapterTotal: widget.chapterTotal,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 数字条当前值：从 137 圈快滚落定到章节号（无进度直开落 001；若经
  /// 目录跳章进未读书，落定所点章节号——ReaderScreen 传的就是当前章）。
  ///
  /// 计数窗内 `Fx.cut` 出力驱动，落定值 = [FxOpenBookRite.chapterNumber]。
  double _counterValue(double t) {
    const int spin = 137;
    final double p = Fx.cut.transform(_countWindow.transform(t));
    return widget.chapterNumber + spin * (1.0 - p);
  }

  /// 刀片半角（弧度）：剪切窗内沿滑行小幅开合，剪完 80ms 张开 + 90ms 合拢。
  double _bladeTheta(double t, double cutT) {
    if (t < _bladeOpenWindow.begin) {
      // 剪切窗：整体随推进收拢 + 4 次开合「咔嚓」。
      final double snip = (math.sin(cutT * math.pi * 8) + 1) / 2;
      final double base = _lerp(_kBladeOpen, _kBladeSnipEnd, cutT);
      return _lerp(base, _kBladeClosed, snip * 0.5);
    }
    if (t < _bladeCloseWindow.begin) {
      // 张开拍：80ms 从收拢角张回全开。
      final double p = Curves.easeOut.transform(_bladeOpenWindow.transform(t));
      return _lerp(_kBladeSnipEnd, _kBladeOpen, p);
    }
    // 合拢拍：90ms 合到「剪断」（之后保持，直到折叠窗结束）。
    final double p = Curves.easeIn.transform(_bladeCloseWindow.transform(t));
    return _lerp(_kBladeOpen, _kBladeClosed, p);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/open_book_rite_test.dart）----

  @visibleForTesting
  double get debugT => _controller.value;

  @visibleForTesting
  double debugCutT(double t) => Fx.cut.transform(_countWindow.transform(t));

  @visibleForTesting
  double debugFoldT(double t) => Fx.fold.transform(_revealWindow.transform(t));

  @visibleForTesting
  double get debugRevealStartT => _revealStartT;

  @visibleForTesting
  Duration? get debugTotalDuration => _controller.duration;
}

/// 三位数字条：三个裁剪盒内的数字卷轴（odometer）+ 章节标签。
class _CounterBar extends StatelessWidget {
  const _CounterBar({
    required this.value,
    required this.digitStyle,
    required this.labelStyle,
    required this.chapterNumber,
    required this.chapterTotal,
  });

  /// 当前显示值（连续，卷轴按小数位平移）。
  final double value;

  final TextStyle digitStyle;
  final TextStyle labelStyle;
  final int chapterNumber;
  final int chapterTotal;

  static const int _kDigits = 3;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: m.s8,
      children: [
        // 实色托底（surface3 不透明）：压在封面下半上仍可读。
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.colors.surface3,
            borderRadius: BorderRadius.all(Radius.circular(m.radiusMd)),
            border: Border.all(color: tokens.colors.hairline),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(m.s16, m.s12, m.s16, m.s12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _kDigits; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      right: i == _kDigits - 1 ? 0 : m.s4,
                    ),
                    child: _Reel(
                      digit: _digitAt(i),
                      fraction: (value / _factor(i)) % 1,
                      style: digitStyle,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Text(
          chapterTotal > 0
              ? '第 $chapterNumber 章 / 共 $chapterTotal 章'
              : '第 $chapterNumber 章',
          style: labelStyle,
        ),
      ],
    );
  }

  int _digitAt(int i) => (value ~/ _factor(i)) % 10;

  int _factor(int i) => math.pow(10, _kDigits - 1 - i).toInt();
}

/// 单个数字卷轴：裁剪盒内一段 0..9 的竖排数字条，按小数位平移——
/// 「计数条裁剪盒内平移」（atlas cut-line-preloader）。
///
/// 单元格宽取「0」的实测宽（[FxGlyphMeter]，数字列全部等宽位图字距），
/// 卷轴条多给一格「0」兜 9→0 的环绕显示。
class _Reel extends StatelessWidget {
  const _Reel({
    required this.digit,
    required this.fraction,
    required this.style,
  });

  final int digit;

  /// 卷轴小数位（0..1）：决定数字条的亚格平移。
  final double fraction;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final FxGlyphMeter meter = FxGlyphMeter();
    meter.updateDirection(TextDirection.ltr);
    final double cellW = meter.widthOf('0', style);
    final double lineH = meter.lineHeight;
    return ClipRect(
      child: SizedBox.fromSize(
        size: Size(cellW, lineH),
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: cellW,
          maxWidth: cellW,
          minHeight: lineH * 11,
          maxHeight: lineH * 11,
          child: Transform.translate(
            offset: Offset(0, -(digit + fraction) * lineH),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var d = 0; d <= 10; d++)
                  Container(
                    height: lineH,
                    width: cellW,
                    alignment: Alignment.center,
                    child: Text('${d % 10}', style: style),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 虚线剪裁线 + 线稿剪刀（两刀片绕 pivot 开合，沿裁剪线推进）。
class _CutLinePainter extends CustomPainter {
  _CutLinePainter({
    required this.inkColor,
    required this.splitY,
    required this.cutT,
    required this.bladeTheta,
  });

  final Color inkColor;
  final double splitY;

  /// 剪切进度 0..1（决定剪刀推进位置）。
  final double cutT;

  /// 刀片半角（弧度）。
  final double bladeTheta;

  @override
  void paint(Canvas canvas, Size size) {
    final double left = size.width * _kScissorInset;
    final double right = size.width * (1 - _kScissorInset);
    final double span = right - left;
    final Paint linePaint = Paint()
      ..color = inkColor.withValues(alpha: 0.55)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final double cutX = left + span * cutT.clamp(0.0, 1.0);
    _drawDashed(canvas, linePaint, Offset(left, splitY), Offset(cutX, splitY));
    _drawDashed(canvas, linePaint, Offset(cutX, splitY), Offset(right, splitY));

    _drawScissors(canvas, Offset(cutX, splitY));
  }

  void _drawDashed(Canvas canvas, Paint paint, Offset from, Offset to) {
    const double gap = 9;
    final double dx = to.dx - from.dx;
    final double dy = to.dy - from.dy;
    final double len = math.sqrt(dx * dx + dy * dy);
    if (len <= 0) return;
    final double ux = dx / len;
    final double uy = dy / len;
    double d = 0;
    while (d < len) {
      final double segEnd = math.min(d + gap, len);
      canvas.drawLine(
        Offset(from.dx + ux * d, from.dy + uy * d),
        Offset(from.dx + ux * segEnd, from.dy + uy * segEnd),
        paint,
      );
      d = segEnd + gap;
    }
  }

  /// 线稿剪刀：pivot 圆点 + 两根刃线（绕 pivot 开 [bladeTheta] 半角）+
  /// 两根柄线（反向）。跟随剪裁线向右推进，刃口朝行进方向。
  void _drawScissors(Canvas canvas, Offset pivot) {
    final Paint stroke = Paint()
      ..color = inkColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const double bladeLen = 26;
    const double handleLen = 20;
    for (final double sign in const <double>[-1, 1]) {
      final double a = sign * bladeTheta;
      final Offset tip =
          pivot + Offset(math.cos(a) * bladeLen, math.sin(a) * bladeLen);
      final Offset handle =
          pivot - Offset(math.cos(a) * handleLen, math.sin(a) * handleLen);
      canvas.drawLine(pivot, tip, stroke);
      canvas.drawLine(pivot, handle, stroke);
    }
    canvas.drawCircle(pivot, 2.4, Paint()..color = inkColor);
  }

  @override
  bool shouldRepaint(_CutLinePainter old) =>
      old.inkColor != inkColor ||
      old.splitY != splitY ||
      old.cutT != cutT ||
      old.bladeTheta != bladeTheta;
}
