/// 段级滚动进度点亮（E3 · atlas reading-word-highlight 的滚动侧对应物）。
///
/// 滚动模式：视口焦点线（屏高 **38%**）以上已读段落全亮、以下未读段落
/// opacity **0.55**（不消失）；边界段随滚动**连续插值**；无 Timer，纯滚动
/// 帧驱动（`FxReadProgress.tick`）；反向滚动可逆。0.38/0.55/0.45 为算法
/// 常量（非时长/曲线/色值），随本文件 dartdoc 落档。
///
/// 叠加纪律：TTS 实心词/句底纹**永不 dim**——接线方（ContinuousChapters）
/// 对朗读高亮段不包 dim 包装（实心/底纹渲染层天然在 dim 之上）。
///
/// 性能：段 wrapper 逐帧只对「透明度变化超阈值的段」setState（可视带边界
/// 附近 ≤2 段），越线段/已读段零重建；开关默认关，关态滚动模式完全不包
/// wrapper（与现状逐字节等价）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../../theme/app_metrics.dart';

/// 焦点线在视口高度中的比例（已读/未读分界）。
const double kFxReadFocusRatio = 0.38;

/// 未读段的 opacity 下限（已读段全亮 1.0，差值 0.45 线性插值）。
const double kFxReadDimMin = 0.55;

/// 纯函数：段矩形 [top, bottom]（视口坐标，向下为正）对焦点线 [focusLine]
/// 的已读度。段底 ≤ 焦线 → 1（全亮）；段顶 ≥ 焦线 → 0（未读）；跨越焦线
/// 的边界段线性插值（随滚动连续变化、可逆）。矩形反序（top > bottom）按
/// 归一化处理，插值对称不越界。
double fxParagraphReadT({
  required double top,
  required double bottom,
  required double focusLine,
}) {
  final lo = math.min(top, bottom);
  final hi = math.max(top, bottom);
  if (hi <= focusLine) return 1.0;
  if (lo >= focusLine) return 0.0;
  final span = hi - lo;
  if (span <= 0) return 1.0;
  return ((focusLine - lo) / span).clamp(0.0, 1.0);
}

/// 纯函数：已读度 → 段透明度（`0.55 + 0.45·readT`，clamp）。
double fxParagraphOpacity(double readT) =>
    kFxReadDimMin + (1 - kFxReadDimMin) * readT.clamp(0.0, 1.0);

/// 段级进度点亮的驱动源。两个信号通道严格分开：
/// - [enabledListenable]（结构变化）：开关翻转时通知列表重建（包/拆
///   wrapper），ContinuousChapters 只听这个，**不**逐帧重建列表；
/// - [tick]（滚动帧）：滚动位置每帧变化调用一次，段 wrapper 监听
///   [ChangeNotifier] 重算自身透明度（无 Timer、无补间，取实时值）。
class FxReadProgress extends ChangeNotifier {
  FxReadProgress({bool enabled = false})
    : _enabled = enabled,
      enabledListenable = ValueNotifier<bool>(enabled);

  bool _enabled;
  bool _introPending = false;

  /// 开关结构变化的通知源（默认关）。
  final ValueNotifier<bool> enabledListenable;

  bool get enabled => _enabled;

  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    _introPending = v;
    enabledListenable.value = v;
  }

  /// 接通后的第一拍给一次 enter 档过渡（设计 §4）；此后滚动帧直接取实时值。
  bool get introPending => _introPending;

  /// 滚动帧驱动：ContinuousChapters 的滚动回调每帧调用一次。
  void tick() {
    if (!_enabled) return;
    _introPending = false;
    notifyListeners();
  }
}

/// 段级 dim 包装：监听 [driver] 的滚动帧，逐帧定位自身矩形（内容坐标是
/// 静态的，`getOffsetToReveal` 换算随滚动逐帧精确、无滞后），只当透明度
/// 变化超阈值时重建。已读段（opacity ≥ 0.999）直接透传 child，零开销。
class FxDimParagraph extends StatefulWidget {
  const FxDimParagraph({
    super.key,
    required this.driver,
    this.intro = true,
    required this.child,
  });

  final FxReadProgress driver;

  /// 挂载首拍是否走一次 enter 档过渡（开关接通时刻的统一渐显）。
  final bool intro;

  final Widget child;

  @override
  State<FxDimParagraph> createState() => _FxDimParagraphState();
}

class _FxDimParagraphState extends State<FxDimParagraph> {
  double _opacity = 1.0;
  bool _introApplied = false;
  bool _introAnimating = false;
  double _introTarget = 1.0;

  @override
  void initState() {
    super.initState();
    widget.driver.addListener(_recalc);
    _scheduleRecalc();
  }

  @override
  void didUpdateWidget(covariant FxDimParagraph old) {
    super.didUpdateWidget(old);
    if (old.driver != widget.driver) {
      old.driver.removeListener(_recalc);
      widget.driver.addListener(_recalc);
    }
    // 列表元素复用换段后重定位（内容坐标变了）。
    _scheduleRecalc();
  }

  @override
  void dispose() {
    widget.driver.removeListener(_recalc);
    super.dispose();
  }

  void _scheduleRecalc() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recalc();
    });
  }

  void _recalc() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final viewport = context
        .findAncestorRenderObjectOfType<RenderAbstractViewport>();
    final scrollable = Scrollable.maybeOf(context);
    if (viewport == null || scrollable == null) return;
    final position = scrollable.position;
    if (position.viewportDimension <= 0) return;
    // 段顶的滚动坐标（滚到该 offset 时段顶恰在视口顶缘）；换算成视口
    // 坐标后与焦点线（视口高的 38%）比较。几何随内容静态，无帧滞后。
    final contentTop = viewport.getOffsetToReveal(box, 0.0).offset;
    final top = contentTop - position.pixels;
    final bottom = top + box.size.height;
    final focus = position.viewportDimension * kFxReadFocusRatio;
    final target = fxParagraphOpacity(
      fxParagraphReadT(top: top, bottom: bottom, focusLine: focus),
    );
    if ((target - _opacity).abs() < 0.004) {
      return; // 越线段/已读段：透明度没动就零重建
    }
    setState(() {
      if (widget.intro && !_introApplied && widget.driver.introPending) {
        _introApplied = true;
        _introAnimating = true;
        _introTarget = target;
        return;
      }
      _introAnimating = false;
      _opacity = target;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_introAnimating) {
      // 开关接通首拍的一次性渐变：TweenAnimationBuilder 在**首次构建**就会
      // 从 begin 动到 end 并回调 onEnd（AnimatedOpacity 首建直接钉在终值、
      // onEnd 永不触发，踩过的坑）。
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 1.0, end: _introTarget),
        duration: AppMetrics.reduceMotionOf(context, AppMetrics.standard.enter),
        onEnd: () {
          if (!mounted) return;
          // onEnd 可能在本组件首次 build 内同步触发（duration 压成零时
          // AnimationController 走同步终值快路径并立刻回调 onEnd）；此时
          // setState 会把正在 rebuild 的自己标 dirty（assert(!_dirty) 崩）。
          // 统一推迟到本帧收尾再落终值，零/非零时长两条路径都安全。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _introAnimating = false;
              _opacity = _introTarget;
            });
          });
        },
        builder: (context, value, child) =>
            Opacity(opacity: value, child: child),
        child: widget.child,
      );
    }
    if (_opacity >= 0.999) return widget.child;
    return Opacity(opacity: _opacity, child: widget.child);
  }
}
