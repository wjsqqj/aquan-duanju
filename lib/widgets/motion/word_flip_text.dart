import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_curves.dart';

/// 遮罩翻词（effect-atlas masked-word-flip 移植 · E0）。
///
/// `ClipRect` 遮罩内旧词上滑出新词下滑入（同步完成，[Fx.glide]）；
/// 行宽取候选词的测量最大宽（TextPainter 缓存），翻动中块不跳。
///
/// 两种模式：
/// - **值驱动**：[WordFlipText]——[value] 变化时翻一次
///   （发现页 AppBar 标题随内容类型切换）；
/// - **循环模式**：[WordFlipText.cycle]——[phrases] 停留
///   [holdDuration]（缺省 `metrics.fxWordHold`）后自动翻下一个，
///   翻完再等下一拍（单发 Timer 链，非 periodic）。
///
/// 翻动中收到新值只排队**一个**（后来的顶掉排队者，atlas 规格照搬）。
/// 「减少动效」：值模式时长归零直接切文本（只压时长不删路径）；
/// 循环模式不启动轮换（AC20）。语义上外层 `Semantics(label: 当前词)`
/// 保证读屏只读到新词、不读双层副本。
class WordFlipText extends StatefulWidget {
  /// 值驱动模式：[value] 变化时翻一次。
  const WordFlipText({
    super.key,
    required this.value,
    this.style,
    this.textAlign = TextAlign.start,
  }) : phrases = null,
       holdDuration = null;

  /// 循环模式：停留 [holdDuration] 后自动翻下一个。
  const WordFlipText.cycle({
    super.key,
    required this.phrases,
    this.holdDuration,
    this.style,
  }) : value = null,
       textAlign = TextAlign.start;

  /// 值驱动模式的当前词。
  final String? value;

  /// 循环模式的候选词（至少 1 个）。
  final List<String>? phrases;

  /// 循环模式停留时长；缺省取 `metrics.fxWordHold`。
  final Duration? holdDuration;

  /// 词的样式；缺省取 `DefaultTextStyle`。
  final TextStyle? style;

  /// 词在测量行宽内的对齐（默认 start，左对齐）。
  final TextAlign textAlign;

  @override
  State<WordFlipText> createState() => _WordFlipTextState();
}

class _WordFlipTextState extends State<WordFlipText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  String _current = '';
  String? _outgoing;
  String? _pending;
  int _cycleIndex = 0;
  Timer? _holdTimer;
  TextDirection _measureDirection = TextDirection.ltr;
  final Map<String, Size> _measureCache = <String, Size>{};

  bool get _isCycle => widget.phrases != null;

  bool get _reduceMotion => AppMetrics.reduceMotionEnabled(context);

  @override
  void initState() {
    super.initState();
    _current = _isCycle ? widget.phrases!.first : widget.value!;
    _controller = AnimationController(vsync: this);
    _controller.addStatusListener(_onFlipStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 时长经 reduceMotionOf：减少动效时归零 → 翻词直接落到新词。
    _controller.duration = AppMetrics.reduceMotionOf(
      context,
      context.app.metrics.fxWordFlip,
    );
    // 方向变化会让 TextPainter 测量失效（宽度随书写方向变）。
    final TextDirection direction = Directionality.of(context);
    if (direction != _measureDirection) {
      _measureDirection = direction;
      _measureCache.clear();
    }
    if (_isCycle) {
      // 减少动效禁用自动轮换；依赖变化（如主题）重排下一拍。
      if (_reduceMotion) {
        _holdTimer?.cancel();
        _holdTimer = null;
      } else {
        _scheduleHold();
      }
    }
  }

  @override
  void didUpdateWidget(covariant WordFlipText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style != oldWidget.style) _measureCache.clear();
    if (_isCycle) {
      if (_phrasesChanged(widget.phrases!, oldWidget.phrases!)) {
        // 候选词换了：从头轮换，翻到新列表首词。有翻动发生时下一拍由
        // _onFlipStatus 链式排（这里再排会出双 Timer）；没翻动（首词与
        // 当前词相同、forward 不会触发 completed 回调）才由这里补排。
        _cycleIndex = 0;
        if (!_flipTo(widget.phrases!.first) && !_reduceMotion) {
          _scheduleHold();
        }
      }
    } else if (widget.value != oldWidget.value) {
      _flipTo(widget.value!);
    }
  }

  bool _phrasesChanged(List<String> a, List<String> b) {
    if (identical(a, b)) return false;
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return true;
    }
    return false;
  }

  /// 发起一次翻词；翻动中收到的新词进排队位（至多 1 个，后来者顶掉）。
  /// 返回是否有翻动发生（false = 新词与当前词相同，无事发生）。
  bool _flipTo(String next) {
    if (next == _current) return false;
    if (_controller.isAnimating) {
      _pending = next;
      return true;
    }
    setState(() {
      _outgoing = _current;
      _current = next;
    });
    _controller.forward(from: 0);
    return true;
  }

  void _onFlipStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_pending != null) {
      final String next = _pending!;
      _pending = null;
      if (_flipTo(next)) return;
      // 排队词与刚落定的词相同：没有新翻动，走落定路径清掉旧词。
    }
    setState(() => _outgoing = null);
    if (_isCycle && !_reduceMotion) _scheduleHold();
  }

  /// 排下一拍：翻完再等 hold（单发 Timer 链，dispose 取消）。
  void _scheduleHold() {
    _holdTimer?.cancel();
    if (!_isCycle || _reduceMotion || !mounted) return;
    final Duration hold = widget.holdDuration ?? context.app.metrics.fxWordHold;
    _holdTimer = Timer(hold, () {
      if (!mounted || _reduceMotion) return;
      // 依赖变化重排出的旧拍撞上未落定的翻动：丢弃这一拍，完成链
      // （_onFlipStatus）落定后会自己排下一拍，不会断轮换。
      if (_controller.isAnimating || _pending != null) return;
      final List<String> phrases = widget.phrases!;
      _cycleIndex = (_cycleIndex + 1) % phrases.length;
      _flipTo(phrases[_cycleIndex]);
    });
  }

  /// 测量候选词（循环模式 = 全部 phrases；值模式 = 出/入/排队词并集）。
  List<String> get _candidates => <String>[_current, ?_outgoing, ?_pending];

  Size _measure(String word, TextStyle style, TextDirection direction) {
    final Size? cached = _measureCache[word];
    if (cached != null) return cached;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: direction,
      maxLines: 1,
    )..layout();
    final Size size = Size(painter.width, painter.height);
    _measureCache[word] = size;
    return size;
  }

  Widget _word(String text, TextStyle style, TextDirection direction) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    textAlign: widget.textAlign,
    style: style,
    textDirection: direction,
  );

  @override
  Widget build(BuildContext context) {
    final TextStyle style = widget.style ?? DefaultTextStyle.of(context).style;
    final TextDirection direction = _measureDirection;
    final List<String> candidates = _isCycle ? widget.phrases! : _candidates;
    double maxWidth = 0;
    double lineHeight = 0;
    for (final String word in candidates) {
      final Size size = _measure(word, style, direction);
      if (size.width > maxWidth) maxWidth = size.width;
      if (size.height > lineHeight) lineHeight = size.height;
    }

    return Semantics(
      label: _current,
      excludeSemantics: true,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 行宽取候选词最宽者；可用宽不够时夹到可用宽（词内 ellipsis）。
            final double width = constraints.hasBoundedWidth
                ? maxWidth < constraints.maxWidth
                      ? maxWidth
                      : constraints.maxWidth
                : maxWidth;
            return SizedBox(
              width: width,
              height: lineHeight,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final String? outgoing = _outgoing;
                  if (outgoing == null) {
                    return _word(_current, style, direction);
                  }
                  // 同步翻带：旧词 0→-100% 上滑出，新词 +100%→0 下滑入。
                  final double t = Fx.glide.transform(_controller.value);
                  return Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.topLeft,
                    children: <Widget>[
                      Transform.translate(
                        offset: Offset(0, -t * lineHeight),
                        child: _word(outgoing, style, direction),
                      ),
                      Transform.translate(
                        offset: Offset(0, (1 - t) * lineHeight),
                        child: _word(_current, style, direction),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _controller.removeStatusListener(_onFlipStatus);
    _controller.dispose();
    super.dispose();
  }
}
