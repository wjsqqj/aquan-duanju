import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_curves.dart';
import 'fx_stagger.dart';

/// 字母上滚的交错槽距（atlas link-hover-set 的 letterRoll 规格）。
///
/// kit 级常量（atlas 出处；微交互内不占五档）。槽位上限沿用
/// `fxCellStaggerDelay` 的 8 槽先例，长标签不至于拖出可见的末字延迟。
const Duration fxRollStagger = Duration(milliseconds: 24);

/// 字母上滚的交错槽位上限（24ms × 8 = 192ms 起跑跨度）。
const int _kRollSlots = 8;

/// 双线追跑文本链接（effect-atlas link-hover-set 移植 · E2）。
///
/// hover 时两道 1px 下划线先后跑：
/// - **accent 线先行**（[AppMetrics.hover] 档，[Fx.glide] 正放），
/// - **ink 线滞后** [fxMotionLag]（60ms）起跑、[AppMetrics.panel] 档
///   追上**盖住** accent——追跑途中露出彩色前缘，落定后是墨色满线；
/// - 离场反序：ink 先退、accent 跟退（单 controller 反放自然给出该序）；
/// - 从当前值续起（`forward/reverse` 不带 `from:`），快速反复不跳变。
///
/// scaleX origin：进入 origin=left、离开 origin=right（追跑方向感）。
///
/// 可选 [letterRoll]：文本拆字符列，每字符 ClipRect 内 100% 上滚（旧字符
/// 上滑出、新字符自下滑入同位），字符间 [fxRollStagger] 交错——共享时钟
/// 同落定语义（[staggeredInterval]，单拍时长随槽位递减），槽位上限 8。
///
/// 门控（AC20）：仅桌面且非 reduceMotion 才装控制器，否则原样透传
/// `Text`（移动端零开销、布局与改前一致）；reduceMotion 下 hover 进出
/// 时长归零直跳终态。
class FxChaseLine extends StatefulWidget {
  const FxChaseLine({
    super.key,
    required this.text,
    this.style,
    this.letterRoll = false,
  });

  /// 链接文本（语义与渲染同一事实源）。
  final String text;

  /// 文本样式；缺省取 `DefaultTextStyle.of(context).style`——ink 线的
  /// 「墨色」也取该样式的颜色（缺省 `colors.textPrimary`）。
  final TextStyle? style;

  /// true = 启用字母逐个上滚（仅桌面动效路径生效）。
  final bool letterRoll;

  @override
  State<FxChaseLine> createState() => _FxChaseLineState();
}

class _FxChaseLineState extends State<FxChaseLine>
    with TickerProviderStateMixin {
  /// 双线共享时钟：accent 窗口 [0, hover]、ink 窗口 [lag, lag+panel]。
  AnimationController? _chase;

  /// letterRoll 时钟（独立于双线：交错跨度可超过双线总长）。
  AnimationController? _roll;

  late final Animation<double> _accent;
  late final Animation<double> _ink;

  /// scaleX origin：true = 左（进入），false = 右（离开）。
  bool _originLeft = true;

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
    if (!desktop || AppMetrics.reduceMotionEnabled(context)) return;
    final AppMetrics m = context.app.metrics;
    // 双线总时长：accent(hover) 与 ink(panel) 重叠 60ms 起跑。
    final Duration total = fxMotionLag + m.panel;
    final double totalMs = total.inMilliseconds.toDouble();
    _chase = AnimationController(vsync: this, duration: total);
    _accent = CurvedAnimation(
      parent: _chase!,
      curve: Interval(0, m.hover.inMilliseconds / totalMs, curve: Fx.glide),
    );
    _ink = CurvedAnimation(
      parent: _chase!,
      curve: Interval(fxMotionLag.inMilliseconds / totalMs, 1, curve: Fx.glide),
    );
    if (widget.letterRoll) {
      final int slots = (widget.text.characters.length - 1).clamp(
        0,
        _kRollSlots,
      );
      final Duration rollTotal = m.hover + fxRollStagger * slots;
      _roll = AnimationController(vsync: this, duration: rollTotal);
    }
  }

  void _onEnter(PointerEnterEvent _) {
    _originLeft = true;
    _chase?.forward();
    _roll?.forward();
  }

  void _onExit(PointerExitEvent _) {
    // 反序离场由单 controller 反放给出：ink（后段窗口）先退、accent 跟退。
    _originLeft = false;
    _chase?.reverse();
    _roll?.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? chase = _chase;
    if (chase == null) {
      // 静态透传（移动/TV/reduceMotion）：与原 Text 渲染一致。
      return Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
    }
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final TextStyle style = widget.style ?? DefaultTextStyle.of(context).style;
    final Color inkColor = style.color ?? tokens.colors.textPrimary;
    final Alignment origin = _originLeft
        ? Alignment.centerLeft
        : Alignment.centerRight;
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: _onEnter,
        onExit: _onExit,
        child: Column(
          // stretch：车道宽度取文本宽（Row 内不会拿到无界宽度）。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildText(context, style),
            // 下划线车道：2px 高（tight），accent 底层先行、ink 顶层追上盖住。
            ConstrainedBox(
              constraints: BoxConstraints.tightFor(height: m.hairline * 2),
              child: AnimatedBuilder(
                animation: chase,
                builder: (context, _) {
                  final double accentT = _accent.value.clamp(0.0, 1.0);
                  final double inkT = _ink.value.clamp(0.0, 1.0);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // accent 线先行（底层）。
                      if (accentT > 0)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: m.hairline,
                          child: Transform.scale(
                            scaleX: accentT,
                            alignment: origin,
                            child: ColoredBox(color: tokens.colors.brand),
                          ),
                        ),
                      // ink 线滞后追上盖住（顶层，露出彩色前缘）。
                      if (inkT > 0)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: m.hairline,
                          child: Transform.scale(
                            scaleX: inkT,
                            alignment: origin,
                            child: ColoredBox(color: inkColor),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文本主体：普通模式单 Text；letterRoll 模式拆字符列逐个上滚。
  Widget _buildText(BuildContext context, TextStyle style) {
    final AnimationController? roll = _roll;
    if (roll == null) {
      return Text(
        widget.text,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
    }
    final List<String> chars = [
      for (final String ch in widget.text.characters) ch,
    ];
    final TextDirection direction = Directionality.of(context);
    return AnimatedBuilder(
      animation: roll,
      builder: (context, _) {
        final double t = roll.value;
        // 全部字符归位（t=1 或未动）时直接给单 Text，省测量与字符列。
        if (t <= 0 || t >= 1) {
          return Text(
            widget.text,
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          textDirection: direction,
          children: [
            for (var i = 0; i < chars.length; i++)
              _rollChar(chars[i], i, t, style, direction),
          ],
        );
      },
    );
  }

  /// 单字符滚轮：ClipRect 视口内旧字符上滑出、新字符自下滑入（同位）。
  Widget _rollChar(
    String ch,
    int index,
    double t,
    TextStyle style,
    TextDirection direction,
  ) {
    final double start = staggeredInterval(
      index,
      base: Duration.zero,
      unit: fxRollStagger,
      total: _roll!.duration!,
    ).begin;
    final double charT = ((t - start) / (1 - start)).clamp(0.0, 1.0);
    final Size size = _measure(ch, style, direction);
    return ClipRect(
      // 视口按实测字符尺寸钉死：滚出/滚入的副本超出即被裁掉。
      child: SizedBox.fromSize(
        size: size,
        child: Stack(
          alignment: Alignment.topLeft,
          children: [
            Transform.translate(
              offset: Offset(0, -Fx.glide.transform(charT) * size.height),
              child: Text(ch, style: style, textDirection: direction),
            ),
            Transform.translate(
              offset: Offset(0, (1 - Fx.glide.transform(charT)) * size.height),
              child: Text(ch, style: style, textDirection: direction),
            ),
          ],
        ),
      ),
    );
  }

  final Map<String, Size> _measureCache = <String, Size>{};

  Size _measure(String ch, TextStyle style, TextDirection direction) {
    final Size? cached = _measureCache[ch];
    if (cached != null) return cached;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: ch, style: style),
      textDirection: direction,
    )..layout();
    final Size size = Size(painter.width, painter.height);
    return _measureCache[ch] = size;
  }

  @override
  void dispose() {
    _chase?.dispose();
    _roll?.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/chase_line_test.dart）----

  @visibleForTesting
  double get debugAccentT => _accent.value;

  @visibleForTesting
  double get debugInkT => _ink.value;

  @visibleForTesting
  bool get debugAnimated => _chase != null;
}
