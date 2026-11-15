/// 章节小地图（E3 · atlas scroll-minimap 示意降级版）。
///
/// 滚动模式右缘窄条地图：每章一段带（高度 ∝ 章字数），当前章 brand 高亮，
/// 1px hairline 视口框标当前位置；点击某章跳转。**分段线性映射**：章 i 的
/// 单位区间 [U_i, U_{i+1}] 线性映到条带 [B_i, B_{i+1}]（间隙不参与比例），
/// 非全段比例映射（atlas 明令比例映射丢框高变化）。
///
/// atlas 双段追踪直译：
/// - 第一段：输入改目标 T（阅读位置 → 单位空间），显示值每帧追
///   （glide 时间常数 **80ms** → rate 12.5）；
/// - 第二段：视口框对映射位置再做二次短追踪（frameLag **40ms** → rate 25）。
///   两个追踪常数均为 atlas `scroll-minimap` 顶部规格注释的原始值，作为
///   kit dartdoc 常量落在本文件。
///
/// 布局：条带静态画（章节变更才 repaint——`shouldRepaint` 比较
/// weights/当前章）；框层独立 painter（repaint: FxDamper onUpdate 写入的
/// ValueListenable，零 widget 重建）。宽屏（≥720dp）常显；窄屏折叠为 4px
/// 细线、点按展开为 56px 面板；翻页模式不挂载（接线方 return shrink）。
/// reduceMotion：追踪退化为 `FxDamper.jumpTo` 直跳。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_damp.dart';

/// 折叠宽（px）：窄屏默认的细线。
const double kFxChapterMapCollapsedWidth = 4.0;

/// 展开宽（px）：atlas thumbWidth 参数同源的面板宽。
const double kFxChapterMapExpandedWidth = 56.0;

/// 折叠态命中区宽（px）：视觉线 4px，触达给到 24px。
const double kFxChapterMapHitWidth = 24.0;

/// 宽屏阈值（逻辑像素）：桌面/平板常显展开条。
const double kFxChapterMapWideWidth = 720.0;

/// 第一段追踪：显示值追目标的时间常数 80ms（atlas glide）→ rate = 1000/80。
const double kFxChapterMapGlideRate = 12.5;

/// 第二段追踪：视口框追映射位置的 frameLag 40ms → rate = 1000/40。
const double kFxChapterMapFrameRate = 25.0;

/// 阅读位置输入：章下标 + 章内比例（0..1）。来自滚动模式的进度回调。
class FxMapPosition {
  const FxMapPosition(this.chapter, this.ratio);

  final int chapter;
  final double ratio;
}

/// 权重整理：非正/非法权重按极小值处理，避免除零（调用方给未加载章的
/// 估计值即可，本函数兜底）。
List<double> fxMapNormalizeWeights(List<double> weights) {
  if (weights.isEmpty) return const <double>[1.0];
  return <double>[for (final w in weights) w.isFinite && w > 0 ? w : 0.001];
}

/// 章内比例 → 单位空间坐标：U_i = Σw[0..i)，单位 = U_i + ratio·w_i。
double fxMapUnitOf(int chapter, double ratio, List<double> weights) {
  final w = fxMapNormalizeWeights(weights);
  final i = chapter.clamp(0, w.length - 1);
  var acc = 0.0;
  for (var k = 0; k < i; k++) {
    acc += w[k];
  }
  return acc + w[i] * ratio.clamp(0.0, 1.0);
}

/// 分段线性映射：单位坐标 → 条带 y。章 i 的单位区间 [U_i, U_{i+1}] 线性
/// 映到条带 [B_i, B_{i+1}]（B 高度 ∝ w_i，间隙不参与比例）。
double fxMapStripY({
  required List<double> weights,
  required double unit,
  required double stripHeight,
}) {
  if (stripHeight <= 0) return 0;
  final w = fxMapNormalizeWeights(weights);
  var acc = 0.0;
  for (var i = 0; i < w.length; i++) {
    final next = acc + w[i];
    if (unit <= next || i == w.length - 1) {
      final frac = next > acc
          ? ((unit - acc) / (next - acc)).clamp(0.0, 1.0)
          : 0.0;
      return (acc + frac * w[i]) / _totalOf(w) * stripHeight;
    }
    acc = next;
  }
  return stripHeight;
}

/// 逆映射：条带 y → 单位坐标（测试与命中用）。
double fxMapUnitAt({
  required List<double> weights,
  required double stripY,
  required double stripHeight,
}) {
  if (stripHeight <= 0) return 0;
  final w = fxMapNormalizeWeights(weights);
  final total = _totalOf(w);
  if (total <= 0) return 0;
  final unit = (stripY.clamp(0.0, stripHeight) / stripHeight) * total;
  // 零权重章不占条带，命中的单位落在下一个非零章带上（fxMapStripY 的
  // 分段插值会把它吸到章边界），这里直接返回数值结果。
  return unit;
}

/// 条带 y → 章下标（点击跳章的目标值）。
int fxMapChapterAt({
  required List<double> weights,
  required double stripY,
  required double stripHeight,
}) {
  if (stripHeight <= 0 || weights.isEmpty) return 0;
  final w = fxMapNormalizeWeights(weights);
  final total = _totalOf(w);
  if (total <= 0) return 0;
  final frac = (stripY.clamp(0.0, stripHeight) / stripHeight) * total;
  var acc = 0.0;
  for (var i = 0; i < w.length; i++) {
    acc += w[i];
    if (frac <= acc || i == w.length - 1) return i;
  }
  return w.length - 1;
}

double _totalOf(List<double> w) {
  var total = 0.0;
  for (final v in w) {
    total += v;
  }
  return total <= 0 ? 1.0 : total;
}

/// 滚动模式右缘章节小地图。数据与事件由接线方（reader_screen）供给：
/// - [weights]：每章相对字数（未加载章给估计值；条带随之逐步精确）；
/// - [position]：当前阅读位置（章下标 + 章内比例），滚动模式 600ms 进度
///   回调节奏更新，双段追踪负责平滑；
/// - [onChapterTap]：点击命中章下标（接线方调 `jumpToChapter`）。
class FxChapterMap extends StatefulWidget {
  const FxChapterMap({
    super.key,
    required this.weights,
    required this.position,
    required this.onChapterTap,
  });

  final List<double> weights;
  final ValueListenable<FxMapPosition> position;
  final ValueChanged<int> onChapterTap;

  @override
  State<FxChapterMap> createState() => FxChapterMapState();
}

class FxChapterMapState extends State<FxChapterMap>
    with TickerProviderStateMixin {
  late final FxDamper _input = FxDamper(
    vsync: this,
    rate: kFxChapterMapGlideRate,
    onUpdate: _retargetFrame,
  );

  /// 第一段：显示滚动值（单位空间）追目标；第二段：框追映射位置。
  late final FxDamper _frame = FxDamper(
    vsync: this,
    rate: kFxChapterMapFrameRate,
    onUpdate: (v) => _boxY.value = v,
  );

  /// 视口框 y（条带坐标）。框层 painter 直接 repaint 它，零 widget 重建。
  final ValueNotifier<double> _boxY = ValueNotifier<double>(0);

  double _stripHeight = 0;
  bool _expanded = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_onPosition);
    _syncImmediately();
  }

  @override
  void didUpdateWidget(covariant FxChapterMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
      _syncImmediately();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = AppMetrics.reduceMotionEnabled(context);
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _input.dispose();
    _frame.dispose();
    _boxY.dispose();
    super.dispose();
  }

  /// 当前框位置（条带坐标）。测试口：断言 reduceMotion 直跳/阻尼追踪。
  double get boxY => _boxY.value;

  double _unitOf(FxMapPosition pos) =>
      fxMapUnitOf(pos.chapter, pos.ratio, widget.weights);

  double _stripYOf(double unit) => fxMapStripY(
    weights: widget.weights,
    unit: unit,
    stripHeight: _stripHeight,
  );

  void _retargetFrame(double unit) => _frame.target = _stripYOf(unit);

  /// 挂载/换输入源时直落当前位置（首帧不飞）。
  void _syncImmediately() {
    final unit = _unitOf(widget.position.value);
    _input.jumpTo(unit);
    _frame.jumpTo(_stripYOf(unit));
    // FxDamper.jumpTo 不触发 onUpdate（契约：调用方自己知道终值），框值手动落。
    _boxY.value = _stripYOf(unit);
  }

  void _onPosition() {
    final unit = _unitOf(widget.position.value);
    if (_reduceMotion) {
      // reduceMotion（AC20）：双段追踪退化为直跳（FxDamper 既定出口）。
      _input.jumpTo(unit);
      _frame.jumpTo(_stripYOf(unit));
      _boxY.value = _stripYOf(unit);
      return;
    }
    _input.target = unit;
  }

  void _onTap(TapUpDetails details) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final wide = MediaQuery.sizeOf(context).width >= kFxChapterMapWideWidth;
    if (!_expanded && !wide) {
      setState(() => _expanded = true);
      return;
    }
    final chapter = fxMapChapterAt(
      weights: widget.weights,
      stripY: details.localPosition.dy,
      stripHeight: box.size.height,
    );
    final pos = widget.position.value;
    if (chapter == pos.chapter) {
      // 命中当前章：宽屏常显不收起；窄屏视为「收起面板」。
      if (!wide) setState(() => _expanded = false);
      return;
    }
    widget.onChapterTap(chapter);
  }

  @override
  Widget build(BuildContext context) {
    _reduceMotion = AppMetrics.reduceMotionEnabled(context);
    final colors = context.app.colors;
    return ValueListenableBuilder<FxMapPosition>(
      valueListenable: widget.position,
      builder: (context, pos, _) {
        final wide = MediaQuery.sizeOf(context).width >= kFxChapterMapWideWidth;
        final expanded = wide || _expanded;
        return Semantics(
          label:
              '章节地图，当前第 ${pos.chapter + 1} 章，'
              '共 ${widget.weights.length} 章',
          textDirection: TextDirection.ltr,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTap,
            child: SizedBox(
              // 命中区宽：展开态即面板宽；折叠态给 24px 触达（视觉线仍 4px，
              // 贴阅读区右 padding，几乎不遮正文）。
              width: expanded
                  ? kFxChapterMapExpandedWidth
                  : kFxChapterMapHitWidth,
              height: double.infinity,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedContainer(
                  duration: AppMetrics.reduceMotionOf(
                    context,
                    AppMetrics.standard.enter,
                  ),
                  width: expanded
                      ? kFxChapterMapExpandedWidth
                      : kFxChapterMapCollapsedWidth,
                  height: double.infinity,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final h = constraints.biggest.height;
                      if (h != _stripHeight) {
                        final first = _stripHeight == 0;
                        _stripHeight = h;
                        // 首帧直落当前位置；高度变化（旋转/展开）按新条带
                        // 重定位（阻尼追踪消化差量）。
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => first ? _syncImmediately() : _onPosition(),
                        );
                      }
                      return CustomPaint(
                        painter: _StripPainter(
                          weights: fxMapNormalizeWeights(widget.weights),
                          current: pos.chapter,
                          bandColor: colors.hairline,
                          activeColor: colors.brand,
                          edgeColor: colors.outline,
                        ),
                        foregroundPainter: _FramePainter(
                          boxY: _boxY,
                          color: colors.textPrimary,
                          width: expanded
                              ? kFxChapterMapExpandedWidth
                              : kFxChapterMapCollapsedWidth,
                        ),
                        child: expanded ? _buildLabel(pos, h) : null,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 展开态条带内标当前章序号（caption 档）。
  Widget _buildLabel(FxMapPosition pos, double stripHeight) {
    final weights = fxMapNormalizeWeights(widget.weights);
    final i = pos.chapter.clamp(0, weights.length - 1);
    var before = 0.0;
    for (var k = 0; k < i; k++) {
      before += weights[k];
    }
    final bandCenter =
        (before + weights[i] / 2) / _totalOf(weights) * stripHeight;
    if (stripHeight <= 0) return const SizedBox.shrink();
    final alignY = ((bandCenter / stripHeight) * 2 - 1).clamp(-1.0, 1.0);
    return Align(
      alignment: Alignment(0, alignY),
      child: Text('${pos.chapter + 1}', style: context.app.textTheme.bodySmall),
    );
  }
}

/// 条带层：章节段带 + 当前章高亮。**静态布局**——shouldRepaint 只比较
/// weights / 当前章 / 配色，位置回调的高频重建不触发 repaint。
class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.weights,
    required this.current,
    required this.bandColor,
    required this.activeColor,
    required this.edgeColor,
  });

  final List<double> weights;
  final int current;
  final Color bandColor;
  final Color activeColor;
  final Color edgeColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;
    final total = _totalOf(weights);
    var acc = 0.0;
    final paint = Paint();
    for (var i = 0; i < weights.length; i++) {
      final top = acc / total * size.height;
      acc += weights[i];
      final bottom = acc / total * size.height;
      if (bottom - top < 0.5) continue;
      paint.color = i == current ? activeColor : bandColor;
      canvas.drawRect(Rect.fromLTWH(0, top, size.width, bottom - top), paint);
    }
    // 右缘 hairline 描边，细线态也能看出条带存在。
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = edgeColor;
    canvas.drawLine(
      Offset(size.width - 0.5, 0),
      Offset(size.width - 0.5, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.current != current ||
      old.bandColor != bandColor ||
      old.activeColor != activeColor ||
      old.edgeColor != edgeColor ||
      !_weightsEqual(old.weights, weights);

  static bool _weightsEqual(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 视口框层：1px hairline 框，repaint 由 [FxDamper] 的 onUpdate 写入
/// [boxY] 驱动（二次短追踪，零 widget 重建）。
class _FramePainter extends CustomPainter {
  _FramePainter({required this.boxY, required this.color, required this.width})
    : super(repaint: boxY);

  final ValueListenable<double> boxY;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final y = boxY.value.clamp(0.0, size.height);
    final paint = Paint()..color = color;
    // 1px hairline 横线横贯条带宽，标当前位置。
    canvas.drawRect(
      Rect.fromLTWH(0, y - 0.5, math.max(0.0, width), 1.0),
      paint,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.color != color || old.width != width;
}
