import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import 'glyph_metrics.dart';

/// 乱码字符集（effect-atlas mask-decode-reveal 的 latin/numeric/symbols
/// 字符集在中文场景的等效替换，E4 design §4）：数字 + 十六进制 + 二值化
/// 块 + 符号——「代码感」配空态文案。
const String kScrambleCharset = '0123456789ABCDEF░▒▓*#?';

/// 字符解码轮数（每轮 [fxDecodeRoundMs] 内确定性替换一次乱码字符）。
const int kDecodeRounds = 3;

/// 单轮乱码刷新间隔：165ms（atlas mask-decode-reveal 字符侧同值）。
const int fxDecodeRoundMs = 165;

/// 字符 stagger：45ms（atlas 同值）。
const int kDecodeStaggerMs = 45;

/// n>12 字符时的 stagger 压缩预算（总交错段 ≈300ms，同 title_bounce 手法）。
const int kDecodeCompressBudgetMs = 300;

/// stagger 压缩的触发字符数。
const int kDecodeCompressFrom = 12;

/// 字符 i 的解码轮数（确定性：`((i*7+3)%3)+1` ∈ {1,2,3}——每字符至少
/// 乱码一轮、至多三轮，锁定时刻在字符间自然错开）。design §4 的
/// f(i) = (i*7+3)%3 按「1 基轮数」取用（0 轮 = 不乱码，浪费效果）。
@visibleForTesting
int fxDecodeRoundCount(int index) => ((index * 7 + 3) % kDecodeRounds) + 1;

/// 字符 i 在乱码轮 step 的乱码字形（确定性伪随机，atlas 纪律：不用真
/// 随机）：`charset[(i*13 + step*7) % len]`——同字符同轮必同字形。
@visibleForTesting
String fxDecodeGlyph(int index, int step) {
  final int pos = (index * 13 + step * 7) % kScrambleCharset.length;
  return kScrambleCharset[pos];
}

/// 中文标题解码期的块状占位（ASCII 乱码在 CJK 语境下像编码损坏）。
///
/// 用户把「还」闪成 `D` 一类拉丁字母读成渲染故障（issue #2 截图），
/// 所以非 ASCII 真字改用二值化块字形；ASCII 真字（数字/字母/半角标点）
/// 仍走 [fxDecodeGlyph]，`0` 闪 `A` 不会被误读。
const String kDecodeBlockGlyphs = '░▒▓█';

/// 字符 i 在乱码轮 step 的块状占位字形（确定性：`(i+step) % len`）。
@visibleForTesting
String fxDecodeBlockGlyph(int index, int step) =>
    kDecodeBlockGlyphs[(index + step) % kDecodeBlockGlyphs.length];

/// 空态标题逐字符乱码解码（effect-atlas mask-decode-reveal 字符侧移植 · E4）。
///
/// 标题先整行呈现乱码，随后按确定性时序逐字符「解码」出真字：
/// - 字符 i 的解码轮数见 [fxDecodeRoundCount]；乱码每
///   [fxDecodeRoundMs]·kDecodeRounds 轮内替换，ASCII 真字字形见
///   [fxDecodeGlyph]，非 ASCII 真字（中文/全角标点）用块状占位
///   [fxDecodeBlockGlyph]——拉丁字母乱码混在中文里像编码损坏（issue #2）；
/// - 字符间 stagger [kDecodeStaggerMs]（n>12 时压缩为 min(45, 300/n)），
///   总时长 = stagger·(n-1) + 165·3——DESIGN.md §6 编排豁免序列（约 1s 级）；
/// - **字宽冻结**：每字符单元格宽取「最终字符宽 + 本格用到的乱码字形宽」
///   的最大值（TextPainter 缓存），乱码期间行宽不抖；解码完成后切回普通
///   `Text`（与既有渲染逐像素一致，中文场景单元格宽 ≈ 最终字宽，切换
///   不跳行）；
/// - 单 AnimationController 驱动（rAF 循环惯例），解码完成即停表；
///   另有「总时长 + 200ms」的 Timer 兜底落定（Ticker 被静音/掉帧时不无限挂乱码）；
/// - [text] 变更重播（空态文案换内容场景）；
/// - keep-alive（`AutomaticKeepAliveClientMixin`）：列表滚出视口保留 State，
///   回来不再从乱码重播；
/// - `Semantics(label: 完整标题)`——读屏只读真字，不读乱码副本。
///
/// 门控（AC20）：「减少动效」静态直出（不装 controller，直接普通 Text）。
class FxDecodeReveal extends StatefulWidget {
  const FxDecodeReveal({
    super.key,
    required this.text,
    this.style,
    this.textAlign,
  });

  /// 完整标题文本（逐字切分按 grapheme）。
  final String text;

  /// 标题样式（空态端传 `tokens.title`）；缺省取 `DefaultTextStyle`。
  final TextStyle? style;

  /// 对齐（空态端传 center）。
  final TextAlign? textAlign;

  @override
  State<FxDecodeReveal> createState() => _FxDecodeRevealState();
}

class _FxDecodeRevealState extends State<FxDecodeReveal>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  AnimationController? _controller;
  List<String> _chars = const <String>[];
  Duration _stagger = const Duration(milliseconds: kDecodeStaggerMs);
  Duration _total = const Duration(
    milliseconds: kDecodeRounds * fxDecodeRoundMs,
  );
  bool _done = false;
  bool _wired = false;

  /// 落定兜底计时器（见 [_armSettleWatchdog]）。
  Timer? _settleTimer;

  /// 列表懒构建离开视口后保留 State：回来不再从乱码重播（issue #2）。
  @override
  bool get wantKeepAlive => true;

  /// 字宽测量（TextPainter 复用 + 缓存；乱码字形与最终字符共用）。
  ///
  /// E5 起提为 motion/ 共享 util（FxSpeedScramble 同手法），测量语义与
  /// E4 原私有实现逐位一致（宽度缓存 + 最近一次行高）。
  final FxGlyphMeter _meter = FxGlyphMeter();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _meter.updateDirection(Directionality.of(context));
    if (_wired) return;
    _wired = true;
    _prepare();
    // 门控（AC20）：「减少动效」静态直出，不装 controller。
    if (AppMetrics.reduceMotionEnabled(context)) return;
    _controller = AnimationController(vsync: this, duration: _total)
      ..addStatusListener(_onStatus);
    _controller!.forward(from: 0);
    _armSettleWatchdog();
  }

  @override
  void didUpdateWidget(covariant FxDecodeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style != oldWidget.style) _meter.clearCache();
    if (widget.text == oldWidget.text || _controller == null) return;
    setState(_prepare);
    _done = false;
    _controller!.duration = _total;
    _controller!.forward(from: 0);
    _armSettleWatchdog();
  }

  /// 落定兜底：controller 依赖 vsync，路由/列表离屏被 TickerMode 静音、
  /// 或主线程被重活压住时动画可能长期停在乱码帧——到点直接切回普通 Text。
  /// 时长取总时长 + 200ms，不改变正常帧率下的落定时刻（结果幂等）。
  void _armSettleWatchdog() {
    _settleTimer?.cancel();
    _settleTimer = Timer(_total + const Duration(milliseconds: 200), () {
      if (mounted && !_done) setState(() => _done = true);
    });
  }

  void _prepare() {
    _chars = widget.text.characters.toList(growable: false);
    _stagger = _staggerFor(_chars.length);
    _total = _totalFor(_chars, _stagger);
  }

  static Duration _staggerFor(int count) {
    if (count > kDecodeCompressFrom) {
      final int ms = (kDecodeCompressBudgetMs / count).round().clamp(
        1,
        kDecodeStaggerMs,
      );
      return Duration(milliseconds: ms);
    }
    return const Duration(milliseconds: kDecodeStaggerMs);
  }

  /// 编排豁免上限（DESIGN.md §6）；极端长文本兜底夹取，不静默超限。
  static const Duration _kTotalCap = Duration(seconds: 2, milliseconds: 400);

  static Duration _totalFor(List<String> chars, Duration stagger) {
    final int last = chars.isEmpty ? 0 : chars.length - 1;
    final Duration total =
        stagger * last +
        const Duration(milliseconds: kDecodeRounds * fxDecodeRoundMs);
    return total > _kTotalCap ? _kTotalCap : total;
  }

  void _onStatus(AnimationStatus status) {
    // 解码完成：停表 + 切回普通 Text（layout 与无动效渲染一致）。
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _done = true);
    }
  }

  TextStyle _resolveStyle(BuildContext context) =>
      widget.style ?? DefaultTextStyle.of(context).style;

  /// 字符 i 的单元格尺寸：最终字符与它用到的全部占位字形取最大宽
  /// （乱码期间行宽不抖）；高取统一行高。测宽走共享 [FxGlyphMeter]。
  Size _cellSize(int index, TextStyle style) {
    final bool block = _useBlockPlaceholder(index);
    return _meter.cellSize(
      char: _chars[index],
      glyphCandidates: <String>[
        for (int step = 0; step < fxDecodeRoundCount(index); step++)
          block ? fxDecodeBlockGlyph(index, step) : fxDecodeGlyph(index, step),
      ],
      style: style,
    );
  }

  /// 该字符是否用块状占位：非 ASCII 真字（中文/全角标点/emoji）为 true。
  bool _useBlockPlaceholder(int index) {
    final String ch = _chars[index];
    return ch.isNotEmpty && ch.codeUnitAt(0) > 0x7F;
  }

  /// 字符 i 在乱码轮 [step] 的占位字形（与 [_cellSize] 候选集同口径）。
  String _placeholder(int index, int step) => _useBlockPlaceholder(index)
      ? fxDecodeBlockGlyph(index, step)
      : fxDecodeGlyph(index, step);

  /// 字符 i 的乱码轮号（窗口未开始时停在 0 轮字形）。
  int _step(int index, double elapsedMs) {
    final int rounds = fxDecodeRoundCount(index);
    final double start = _stagger.inMilliseconds * index.toDouble();
    final double rel = (elapsedMs - start)
        .clamp(0.0, (rounds * fxDecodeRoundMs - 0.001).toDouble())
        .toDouble();
    return (rel / fxDecodeRoundMs).floor().clamp(0, rounds - 1);
  }

  bool _decoded(int index, double elapsedMs) {
    final double lock =
        _stagger.inMilliseconds * index.toDouble() +
        fxDecodeRoundCount(index) * fxDecodeRoundMs;
    return elapsedMs >= lock;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin：登记 keep-alive。
    final AnimationController? controller = _controller;
    if (controller == null || _done) {
      // 静态直出（reduceMotion / 解码完成后的稳态）：普通 Text。
      return Text(
        widget.text,
        style: _resolveStyle(context),
        textAlign: widget.textAlign,
      );
    }
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final TextStyle style = _resolveStyle(context);
          final double elapsedMs = controller.value * _total.inMilliseconds;
          return Text.rich(
            TextSpan(
              style: style,
              children: <InlineSpan>[
                for (int i = 0; i < _chars.length; i++)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: _cell(i, style, elapsedMs),
                  ),
              ],
            ),
            textAlign: widget.textAlign ?? TextAlign.start,
          );
        },
      ),
    );
  }

  /// 单字符单元格：冻结宽高；解码完成切真字，否则渲染当轮占位字形。
  Widget _cell(int index, TextStyle style, double elapsedMs) {
    final bool decoded = _decoded(index, elapsedMs);
    final String shown =
        decoded ? _chars[index] : _placeholder(index, _step(index, elapsedMs));
    return SizedBox.fromSize(
      size: _cellSize(index, style),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(shown, style: style, maxLines: 1, softWrap: false),
      ),
    );
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _controller?.removeStatusListener(_onStatus);
    _controller?.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/decode_reveal_test.dart）----

  @visibleForTesting
  bool get debugAnimated => _controller != null;

  @visibleForTesting
  int get debugCharCount => _chars.length;

  @visibleForTesting
  bool debugDecoded(int index) =>
      _decoded(index, (_controller?.value ?? 1) * _total.inMilliseconds);

  @visibleForTesting
  String debugGlyph(int index) => _placeholder(
    index,
    _step(index, (_controller?.value ?? 0) * _total.inMilliseconds),
  );
}
