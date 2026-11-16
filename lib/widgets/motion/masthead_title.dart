import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';

/// 滚动揭示进度纯函数：p = clamp(offset / threshold, 0, 1)。
///
/// 独立成函数便于 0/中值/1 三帧的进度派生测试（atlas poster-masthead-
/// collapse 的「单 progress 驱动」纪律——分段独立 tween 在 scrub 时漂移，
/// 这里全派生自同一个 p）。
@visibleForTesting
double fxMastheadProgress(double offset, double threshold) {
  if (threshold <= 0) return 1;
  return (offset / threshold).clamp(0.0, 1.0);
}

/// 详情刊头标题的滚动裁切揭示（effect-atlas poster-masthead-collapse
/// 概念改编移植 · E2）。
///
/// 问题：详情 SliverAppBar 的标题与 header 的 h1 在页顶重复出现。改编：
/// 滚动 offset 0→threshold（约 header 高度）时，AppBar 标题以「逐段裁切
/// 露出」方式显现——`ClipRect` 硬边从左向右揭示 + 前缘 1px brand 竖线
/// 先行；反向滚动收回。**字母被切掉不是溶解**：主揭示是硬边裁切，不做
/// opacity 渐变为主。
///
/// 进度驱动（无 Timer）：`ListenableBuilder(scrollController)` 读
/// offset 派生 p（[fxMastheadProgress]）。p∈{0,1} 是两帧静态；p=0 时
/// `ClipRect` 只裁绘不裁布局（占位宽保持原 Text 尺寸）——AppBar 布局
/// 不跳（见 _RevealClipper）。
///
/// 门控：reduceMotion / TV 分栏布局下 p 恒 1（静态全显标题，回到现状，
/// 不隐藏）。
class FxMastheadTitle extends StatelessWidget {
  const FxMastheadTitle({
    super.key,
    required this.scrollController,
    required this.title,
    this.threshold = 180,
  });

  /// 页面滚动控制器（detail_screen 的 `_pageScroll`）。
  final ScrollController scrollController;

  final String title;

  /// 揭示完成阈值（offset 达到即全显）；取 header 高度估计，调用方可传。
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    // reduceMotion：p 恒 1 静态全显（条件分支样式，AC20）。
    final double Function(double) progress = _progressFactory(context);
    return ListenableBuilder(
      listenable: scrollController,
      builder: (context, _) {
        final double p = scrollController.hasClients
            ? progress(scrollController.offset)
            : 1;
        return Stack(
          children: [
            ClipRect(
              clipper: _RevealClipper(p),
              // 最多两行：单行省略会把长剧名截成「…」，用户看不到完整名字。
              // 仍放不下时悬停/长按看 tooltip（标题栏高度由调用方给足）。
              child: Tooltip(
                message: title,
                waitDuration: const Duration(milliseconds: 400),
                child: Text(
                  title,
                  style: tokens.title,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // 前缘 1px brand 竖线：只在揭示途中可见（p∈(0,1)）。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _EdgeLinePainter(
                    p: p,
                    color: tokens.colors.brand,
                    width: tokens.metrics.hairline,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 进度派生工厂：默认 p = clamp(offset/threshold)；reduceMotion 恒 1。
  double Function(double) _progressFactory(BuildContext context) {
    if (AppMetrics.reduceMotionEnabled(context)) {
      return (_) => 1;
    }
    return (double offset) => fxMastheadProgress(offset, threshold);
  }
}

/// 硬边揭示裁切：宽 = size.width·p，高全量。p=0 裁成零宽——**布局尺寸
/// 不变**（ClipRect 裁绘不裁布局），AppBar 的标题槽位保持原宽，不跳。
class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.p);

  final double p;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * p.clamp(0.0, 1.0), size.height);

  @override
  bool shouldReclip(_RevealClipper oldDelegate) => oldDelegate.p != p;
}

/// 前缘竖线：在揭示边 x = width·p 处画 1px brand 竖线；p∈{0,1} 不画。
class _EdgeLinePainter extends CustomPainter {
  _EdgeLinePainter({required this.p, required this.color, required this.width});

  final double p;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (p <= 0 || p >= 1) return;
    final Paint paint = Paint()..color = color;
    final double x = (size.width * p).clamp(0.0, size.width);
    canvas.drawRect(Rect.fromLTWH(x - width, 0, width, size.height), paint);
  }

  @override
  bool shouldRepaint(_EdgeLinePainter oldDelegate) =>
      oldDelegate.p != p || oldDelegate.color != color;
}
