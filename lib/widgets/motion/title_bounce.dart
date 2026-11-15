import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';

/// 标题逐字弹跳入场（effect-atlas scroll-story 降编移植 · E4）。
///
/// 详情 h1 逐字入场：字符从下方 24px 弹起（atlas 600px 是巨幅 display 场景，
/// h1 30px 级按比例降）+ 旋转 6°→0（atlas 30° 降），曲线 `Curves.elasticOut`
/// （atlas elastic.out(1,1) 的 Flutter 内置近似），字符 stagger 35ms（atlas
/// 同值）。atlas 的手绘波浪下划线**不移植**——详情标题无强调词语义。
///
/// 编排细节（design §2）：
/// - 单 AnimationController，总时长 = 600ms + stagger·(n-1)——DESIGN.md §6
///   「进场编排」豁免序列（cap 2.4s；超限即压缩 stagger，见 [_TitleBounceTuning]）；
/// - 字符 i 的局部进度 = 全局 [Interval] 窗口映射，窗口长 600ms；
/// - 透明度在每字符窗口前 40% 完成（弹跳期间可见，不闪现）；
/// - n>16 字符时 stagger 压缩为 min(35, 300/n)，防长标题超时长上限；
/// - 逐字 [WidgetSpan] 共用一个 `Text.rich`（保排版一致 + 自然换行），
///   `Semantics(label: 完整标题)` 保证读屏只读整句、不读逐字副本；
/// - 触发：挂载后 post-frame 启动（首帧不闪半程态）——详情数据到达即播，
///   每次打开详情播一次（「开演」仪式的一部分）；[text] 变更重播
///   （详情换剧复用组件树场景）。
///
/// 门控（AC20）：「减少动效」静态直出（不装 controller）。
class FxTitleBounce extends StatefulWidget {
  const FxTitleBounce({
    super.key,
    required this.text,
    this.style,
    this.textAlign,
  });

  /// 完整标题文本（逐字切分按 grapheme，中文天然逐字）。
  final String text;

  /// 标题样式（详情端传 `tokens.h1`）；缺省取 `DefaultTextStyle`。
  final TextStyle? style;

  /// 对齐（缺省 Text 默认 start）。
  final TextAlign? textAlign;

  @override
  State<FxTitleBounce> createState() => _FxTitleBounceState();
}

/// 弹跳参数（kit 级常量，atlas scroll-story 出处；E4 design §2 降编值）。
abstract final class _TitleBounceTuning {
  /// 单字符弹跳窗口：600ms（atlas scroll-story 同值）。
  static const Duration charBounce = Duration(milliseconds: 600);

  /// 字符 stagger：35ms（atlas 同值）。
  static const Duration stagger = Duration(milliseconds: 35);

  /// n>16 字符时的 stagger 压缩预算：交错段总量 ≈300ms（防长标题超 cap）。
  static const int staggerCompressBudgetMs = 300;

  /// stagger 压缩的触发字符数。
  static const int staggerCompressFrom = 16;

  /// 起跳落差：24px（atlas 600px display 按 h1 比例降；取值对齐 s24 刻度）。
  static const double risePx = AppSpacing.s24;

  /// 入场旋转：6°→0（atlas 30° 降），逐字符方向交替。
  static const double rotateRadians = 6.0 * math.pi / 180.0;

  /// 透明度完成窗口（每字符局部进度的前 40%）。
  static const double fadeWindow = 0.4;

  /// 编排豁免单序列上限（DESIGN.md §6）；超出即压缩 stagger，不静默超限。
  static const Duration totalCap = Duration(seconds: 2, milliseconds: 400);
}

class _FxTitleBounceState extends State<FxTitleBounce>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  List<String> _chars = const <String>[];
  Duration _stagger = _TitleBounceTuning.stagger;
  bool _wired = false;

  late Duration _total = _TitleBounceTuning.charBounce;

  /// 字符窗口占全局进度的比例（总时长变化时随之重算）。
  double get _charWindowFraction =>
      _TitleBounceTuning.charBounce.inMicroseconds / _total.inMicroseconds;

  void _prepare() {
    _chars = widget.text.characters.toList(growable: false);
    _stagger = _staggerFor(_chars.length);
    _total = _totalFor(_chars, _stagger);
  }

  static Duration _totalFor(List<String> chars, Duration stagger) {
    if (chars.length <= 1) return _TitleBounceTuning.charBounce;
    final Duration total =
        _TitleBounceTuning.charBounce + stagger * (chars.length - 1);
    // 极端长文本兜底：编排豁免 cap 2.4s（超限时尾部字符窗口重叠收尾）。
    return total > _TitleBounceTuning.totalCap
        ? _TitleBounceTuning.totalCap
        : total;
  }

  static Duration _staggerFor(int count) {
    if (count > _TitleBounceTuning.staggerCompressFrom) {
      final double compressed =
          _TitleBounceTuning.staggerCompressBudgetMs / count;
      final int ms = compressed.round().clamp(
        1,
        _TitleBounceTuning.stagger.inMilliseconds,
      );
      return Duration(milliseconds: ms);
    }
    return _TitleBounceTuning.stagger;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    _prepare();
    // 门控（AC20）：「减少动效」静态直出，不装 controller。
    if (AppMetrics.reduceMotionEnabled(context)) return;
    _controller = AnimationController(vsync: this, duration: _total)
      ..addStatusListener(_onStatus);
    // 首建 post-frame 启动：首帧画 t=0（全透明落位下方），不闪半程态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller?.forward(from: 0);
    });
  }

  @override
  void didUpdateWidget(covariant FxTitleBounce oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文本变更重播（详情换剧复用组件树）；reduceMotion 静态态无需重播。
    if (widget.text == oldWidget.text || _controller == null) return;
    setState(_prepare);
    _controller!.duration = _total;
    _controller!.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (controller == null || controller.isCompleted) {
      // 静态直出（reduceMotion / 播完后的稳态）：与无动效时逐像素一致。
      return Semantics(
        label: widget.text,
        excludeSemantics: true,
        child: Text(
          widget.text,
          style: widget.style,
          textAlign: widget.textAlign,
        ),
      );
    }
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final TextStyle style =
              widget.style ?? DefaultTextStyle.of(context).style;
          return Text.rich(
            TextSpan(
              style: style,
              children: <InlineSpan>[
                for (int i = 0; i < _chars.length; i++)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: _char(i, _chars[i], style),
                  ),
              ],
            ),
            textAlign: widget.textAlign ?? TextAlign.start,
          );
        },
      ),
    );
  }

  /// 字符 i 的入场态：下落 24px→0（elasticOut 过冲会先弹过头再落稳），
  /// 旋转 6°·(1-t) 方向交替，透明度前 40% 完成。
  Widget _char(int index, String char, TextStyle style) {
    final double t = _charProgress(index, _controller!.value);
    final double elastic = Curves.elasticOut.transform(t);
    final double direction = index.isEven ? 1 : -1;
    return Opacity(
      opacity: Curves.easeOut.transform(
        (t / _TitleBounceTuning.fadeWindow).clamp(0.0, 1.0),
      ),
      child: Transform.translate(
        offset: Offset(0, _TitleBounceTuning.risePx * (1 - elastic)),
        child: Transform.rotate(
          angle: direction * _TitleBounceTuning.rotateRadians * (1 - t),
          alignment: Alignment.center,
          child: Text(char, style: style),
        ),
      ),
    );
  }

  /// 字符 i 的局部进度：全局进度经 [Interval(i·stagger, i·stagger+600ms)] 映射。
  double _charProgress(int index, double global) {
    final double begin =
        _stagger.inMicroseconds * index / _total.inMicroseconds;
    final double end = (begin + _charWindowFraction).clamp(begin, 1.0);
    if (global <= begin) return 0;
    if (global >= end) return 1;
    return (global - begin) / (end - begin);
  }

  @override
  void dispose() {
    _controller?.removeStatusListener(_onStatus);
    _controller?.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/title_bounce_test.dart）----

  @visibleForTesting
  bool get debugAnimated => _controller != null;

  @visibleForTesting
  double debugCharProgress(int index) =>
      _charProgress(index, _controller?.value ?? 0);

  @visibleForTesting
  int get debugCharCount => _chars.length;
}
