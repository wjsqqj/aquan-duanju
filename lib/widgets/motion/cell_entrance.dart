import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_curves.dart';
import 'fx_stagger.dart';

/// 首屏交错延迟（design §3）：`min(index, 8)` 槽位 × 40ms，上限 320ms。
///
/// 40ms 槽距与 8 槽上限是 smear-in-grid 的编排参数（kit 级常量，atlas 出处；
/// 入场交错属 DESIGN.md §6 编排豁免序列，不占五档）。调用方只传 index，
/// 编排数学留在 kit。
Duration fxCellStaggerDelay(int index) => staggeredDelay(
  math.min(index, _kStaggerSlots),
  base: Duration.zero,
  unit: _kStaggerUnit,
);

/// 交错槽位上限（8 × 40ms = 320ms cap）。
const int _kStaggerSlots = 8;

/// 交错槽距。
const Duration _kStaggerUnit = Duration(milliseconds: 40);

/// 网格单元首现 smear 入场（effect-atlas smear-in-grid 降编移植 · E1）。
///
/// 单拍（[AppMetrics.fxCellEnter] 360ms）：scaleY 0.92→1（[Fx.spring] 过冲，
/// 上限 ≈1.007）+ opacity 0→1（[Fx.glide]，前 60% 时程）+ 8px 上浮
/// （s8 刻度）。全程 transform + opacity，**无 per-frame layout**。
///
/// 桌面端 2px blur 渐散（ImageFiltered）经评估**整体不启用**：网格滚动中
/// 的全屏 filter 是掉帧大户（design §7 权衡——验收以无 blur 版为准），
/// 构造参数不留口，防调用方误开。
///
/// 「每格只播一次」由调用方（SliverSeriesGrid / SeriesGrid 的 `_entered`
/// 集合）经 [play] 控制：
/// - false 或「减少动效」→ 直跳终态（首帧即满值，无闪帧，无动画子树）；
/// - true → 播一次；播放中途 play 翻 false **不打断**（State 一次性接线，
///   didUpdateWidget 忽略，防重建时卸载动画子树造成回跳）。
/// - 滚动往返导致 State 重建时，调用方以 play=false 复挂 → 静态直出，
///   不重播。
class FxCellEntrance extends StatefulWidget {
  const FxCellEntrance({
    super.key,
    required this.child,
    this.play = true,
    this.delay = Duration.zero,
  });

  final Widget child;

  /// true = 首次出现（播入场）；false = 该 id 已播过（静态直出）。
  final bool play;

  /// 交错延迟（只在首建时生效，重建不重读）。
  final Duration delay;

  @override
  State<FxCellEntrance> createState() => _FxCellEntranceState();
}

class _FxCellEntranceState extends State<FxCellEntrance>
    with SingleTickerProviderStateMixin {
  /// 起始 scaleY（smear 压扁量）。
  static const double _kBaseScaleY = 0.92;

  /// scaleY 行程：0.92 + 0.08·spring(t)，spring 峰值 ≈1.09 → 上限 ≈1.007。
  static const double _kScaleSpan = 0.08;

  /// 淡入窗口（前 60% 时程完成 opacity）。
  static const double _kFadeWindow = 0.6;

  late final AnimationController _controller;
  Timer? _startTimer;
  bool _wired = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    final Duration duration = AppMetrics.reduceMotionOf(
      context,
      context.app.metrics.fxCellEnter,
    );
    if (!widget.play || duration == Duration.zero) {
      // 直跳终态：reduceMotion 归零 / 该 id 已播过。
      _controller.value = 1;
      return;
    }
    _playing = true;
    _controller.duration = duration;
    if (widget.delay == Duration.zero) {
      _controller.forward(from: 0);
    } else {
      // 交错：延后起跑（此 Flutter 版本的 forward 没有 delay 参数）。
      _startTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward(from: 0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_playing) return widget.child;
    final double lift = context.app.metrics.s8;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = _controller.value;
        final double scaleY =
            _kBaseScaleY + _kScaleSpan * Fx.spring.transform(t);
        final double opacity = Fx.glide.transform(
          math.min(1.0, t / _kFadeWindow),
        );
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            // 上浮 8px（s8 刻度）。
            offset: Offset(0, (1 - t) * lift),
            child: Transform(
              alignment: Alignment.bottomCenter,
              transform: Matrix4.diagonal3Values(1.0, scaleY, 1.0),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }
}
