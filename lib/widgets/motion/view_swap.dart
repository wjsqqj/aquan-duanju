import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../tv_scope.dart';
import 'fx_curves.dart';

/// 出拍：旧视图整层上滑出视口（atlas line-by-line-handoff 的 outDuration 320ms，
/// 「出快」半拍）。kit 编排常量（DESIGN.md §6 编排豁免，atlas 出处）。
const Duration fxViewSwapOutMs = Duration(milliseconds: 320);

/// hold 拍：旧层已清场、新层未起——只有底色的空窗（atlas「180ms 只有 logo」
/// 的语义；此处页面无常驻 logo，等价纯底色）。kit 编排常量（atlas 同值）。
const Duration fxViewSwapHoldMs = Duration(milliseconds: 180);

/// 入拍：新视图整层升起就位的基础时长（atlas line-by-line-handoff 的
/// inDuration 760ms，「入慢」半拍）。kit 编排常量（atlas 出处）。
const Duration fxViewSwapInMs = Duration(milliseconds: 760);

/// 出拍行交错：每行遮罩错开 24ms（atlas 出块序 24ms 交错）。
const Duration fxViewSwapOutStagger = Duration(milliseconds: 24);

/// 入拍行交错：每行错开 45ms（atlas lineStagger 45ms）。
const Duration fxViewSwapInStagger = Duration(milliseconds: 45);

/// 行数上限（「可视首屏行」cap 8——交错跨度不至于吃掉主拍）。
const int kViewSwapMaxRows = 8;

/// 出拍整层位移：-106% 层高（atlas 行出遮罩 translateY(-106% - .3em) 的
/// 等效整层量，余量给下伸部）。
const double fxViewSwapOutOffset = 1.06;

/// 入拍整层位移：+112% 层高（atlas 行入遮罩 112% + .3em 的等效整层量）。
const double fxViewSwapInOffset = 1.12;

/// 逐行视图切换（effect-atlas line-by-line-handoff 移植 · E5）。
///
/// `listenable` 翻转时旧视图「出快」上滑出视口（[fxViewSwapOutMs] +
/// 行交错 [fxViewSwapOutStagger]）→ [fxViewSwapHoldMs] 只有底色 → 新视图
/// 「入慢」逐行升起（[fxViewSwapInMs] + 行交错 [fxViewSwapInStagger]）；
/// 曲线统一 [Fx] 族（出 [Fx.glideOut] / 入 [Fx.glide]）。列表 ↔ 3D 双向
/// 都播：单 [AnimationController] forward/reverse——reverse 时同一时间轴
/// 倒放，出/入语义自然对调（atlas「倒放 = 同一曲线反向，不是另编一套」）。
///
/// **单实例行交错**：行 = 内容上的 alpha 波段（ShaderMask dstIn），不把
/// 子树复制成行——业务视图内含 ScrollController / 焦点树，复制实例会重复
/// 挂 controller，还会引入第二滚动视口。整层位移 + 行波段 alpha 是该手法
/// 在「任意子树」约束下的降编（任务报告已注明）。
///
/// 门控（AC20）：「减少动效」/TV 直切（无包装层，直接返回当前视图）。
/// [swapInProgress] 供进场编排互斥（如 3D 书架扇入不与切换叠加）。
class FxViewSwap extends StatefulWidget {
  const FxViewSwap({
    super.key,
    required this.listenable,
    required this.first,
    required this.second,
    this.rows = kViewSwapMaxRows,
  });

  /// 视图模式：false = [first]（如列表），true = [second]（如 3D 书架）。
  final ValueListenable<bool> listenable;

  /// false 态视图。
  final Widget first;

  /// true 态视图。
  final Widget second;

  /// 行交错波段数（可视首屏行，cap [kViewSwapMaxRows]）。
  final int rows;

  /// 切换动画进行中（编排互斥用）。完成拍先保持 true——稳态重建会让入场的
  /// 子树卸下包层**重挂树**，此刻仍须让重挂载的进场编排（如 3D 书架扇入）
  /// 读到互斥标志跳过，帧末回落 false（计数守恒不变）。
  static bool get swapInProgress => _swapDepth > 0;
  static int _swapDepth = 0;

  @override
  State<FxViewSwap> createState() => _FxViewSwapState();
}

class _FxViewSwapState extends State<FxViewSwap>
    with SingleTickerProviderStateMixin {
  /// null = 直切形态（reduceMotion / TV）：不装控制器。
  AnimationController? _controller;

  /// 已落定的视图（与 controller 静止值一致：false=0 / true=1）。
  bool _showSecond = false;

  /// 一次切换只计一次进行中（中途反向不重复计数）。
  bool _counted = false;

  int _rows = kViewSwapMaxRows;

  @override
  void initState() {
    super.initState();
    _showSecond = widget.listenable.value;
    widget.listenable.addListener(_onModeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _rows = widget.rows.clamp(1, kViewSwapMaxRows);
    // 门控（AC20）：reduceMotion / TV 直切——焦点导航优先，不抢过渡拍。
    final bool tv = TvScope.isTvOf(context);
    final bool reduce = AppMetrics.reduceMotionEnabled(context);
    if (tv || reduce) return;
    _controller = AnimationController(vsync: this, duration: _total(_rows))
      ..addStatusListener(_onStatus)
      ..value = _showSecond ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant FxViewSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_onModeChanged);
      widget.listenable.addListener(_onModeChanged);
      // listenable 换实例 = 消费方重建了模式源（如持久化偏好异步就绪）：
      // 跳到当前值，不播过渡（首建语义）。
      _jumpTo(widget.listenable.value);
    }
  }

  Duration _total(int rows) {
    final int extra = rows - 1;
    return fxViewSwapOutMs +
        fxViewSwapOutStagger * extra +
        fxViewSwapHoldMs +
        fxViewSwapInMs +
        fxViewSwapInStagger * extra;
  }

  void _onModeChanged() {
    if (!mounted) return;
    final bool target = widget.listenable.value;
    final AnimationController? controller = _controller;
    if (controller == null) {
      if (target != _showSecond) setState(() => _showSecond = target);
      return;
    }
    if (target == _showSecond && !controller.isAnimating) return;
    _showSecond = target;
    if (!_counted) {
      _counted = true;
      FxViewSwap._swapDepth++;
    }
    setState(() {
      if (target) {
        controller.forward();
      } else {
        controller.reverse();
      }
    });
  }

  void _jumpTo(bool value) {
    _showSecond = value;
    final AnimationController? controller = _controller;
    if (controller == null) {
      setState(() {});
      return;
    }
    if (controller.isAnimating) {
      _releaseCount();
    }
    controller.stop();
    controller.value = value ? 1 : 0;
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      // 先重建稳态（本拍卸包层、入场子树重挂树），swapInProgress 保持
      // true 让重挂载的进场编排读到互斥；帧末再回落计数。
      if (mounted) setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseCount());
    }
  }

  void _releaseCount() {
    if (_counted) {
      _counted = false;
      FxViewSwap._swapDepth--;
    }
  }

  // 段边界（相对 total 的比例）。
  double _outEnd(int rows) {
    final Duration span = fxViewSwapOutMs + fxViewSwapOutStagger * (rows - 1);
    return span.inMicroseconds / _total(rows).inMicroseconds;
  }

  double _holdEnd(int rows) {
    final Duration span =
        fxViewSwapOutMs + fxViewSwapOutStagger * (rows - 1) + fxViewSwapHoldMs;
    return span.inMicroseconds / _total(rows).inMicroseconds;
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (controller == null || !controller.isAnimating) {
      // 稳态（直切形态 / 未在切换）：直接给当前视图，零包装层。
      return _showSecond ? widget.second : widget.first;
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final double t = controller.value;
        final int rows = _rows;
        final double outEnd = _outEnd(rows);
        final double holdEnd = _holdEnd(rows);
        return LayoutBuilder(
          builder: (context, constraints) {
            final double h = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 0;
            if (t < outEnd) {
              // 出拍：旧视图上滑出视口（出快）+ 行 alpha 交错退场。
              final double p = (t / outEnd).clamp(0.0, 1.0);
              return ClipRect(
                child: Transform.translate(
                  offset: Offset(
                    0,
                    -fxViewSwapOutOffset * h * Fx.glideOut.transform(p),
                  ),
                  child: _MaskedLayer(
                    rows: rows,
                    progress: Fx.glideOut.transform(p),
                    appearing: false,
                    child: widget.first,
                  ),
                ),
              );
            }
            if (t < holdEnd) {
              // hold 拍：只有底色（旧层已清场、新层未起）。
              return const SizedBox.shrink();
            }
            // 入拍：新视图升起（入慢）+ 行 alpha 交错进场。
            final double span = 1 - holdEnd;
            final double p = ((t - holdEnd) / span).clamp(0.0, 1.0);
            return ClipRect(
              child: Transform.translate(
                offset: Offset(
                  0,
                  fxViewSwapInOffset * h * (1 - Fx.glide.transform(p)),
                ),
                child: _MaskedLayer(
                  rows: rows,
                  progress: Fx.glide.transform(p),
                  appearing: true,
                  child: widget.second,
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _releaseCount();
    widget.listenable.removeListener(_onModeChanged);
    _controller?.removeStatusListener(_onStatus);
    _controller?.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/view_swap_test.dart）----

  @visibleForTesting
  bool get debugAnimated => _controller != null;

  @visibleForTesting
  bool get debugShowSecond => _showSecond;

  @visibleForTesting
  int get debugRows => _rows;

  /// 行波段 alpha 公式直查（测试锁：末行必须留实窗，见 [_MaskedLayer._bandAlpha]）。
  @visibleForTesting
  double debugBandAlpha(int index, int rows, double progress, bool appearing) =>
      _MaskedLayer._bandAlpha(index, rows, progress, appearing);
}

/// 行波段 alpha 层：把层高分成 [rows] 个水平波段，波段 i 的 alpha 随
/// [progress] 按行交错 ramp——「行级」交错在单内容实例下的降编实现。
///
/// [appearing] = true 进场（波段自 0 升到 1），false 离场（自 1 降到 0）；
/// 位移（整层 ±106%/112%）由外层 Transform 承担，本层只管行 alpha。
class _MaskedLayer extends StatelessWidget {
  const _MaskedLayer({
    required this.rows,
    required this.progress,
    required this.appearing,
    required this.child,
  });

  final int rows;
  final double progress;
  final bool appearing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0;
        final double h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0;
        final Shader shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            for (int i = 0; i < rows; i++)
              Color.fromRGBO(
                255,
                255,
                255,
                _bandAlpha(i, rows, progress, appearing),
              ),
          ],
        ).createShader(Offset.zero & Size(w, h));
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (_) => shader,
          child: child,
        );
      },
    );
  }

  /// 波段 i 的 alpha：行 i 的起跑点 = i/rows（行交错已折进总时长，每行
  /// ramp 占满剩余跨度、全部在拍尾同时落定；末行留 1/rows 实窗——起跑点
  /// 若取 i/(rows-1) 则末行窗长为 0，整拍不可见、收尾帧闪现，质检修正）。
  static double _bandAlpha(
    int index,
    int rows,
    double progress,
    bool appearing,
  ) {
    final double lead = rows <= 1 ? 0.0 : index / rows;
    final double local = ((progress - lead) / (1 - lead)).clamp(0.0, 1.0);
    return appearing ? local : 1 - local;
  }
}
