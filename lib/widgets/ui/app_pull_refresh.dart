import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../jelly/jelly_progress_thumb.dart' show dropletPath;
import '../loading.dart';

/// 品牌下拉刷新（design.md §3.1）：API 仿 Material [RefreshIndicator]。
///
/// 内部按 child 的滚动结构二选一：
///
/// - **sliver 路线**（child 是 `CustomScrollView`）：复制一份并在 slivers
///   前端并入 [CupertinoSliverRefreshControl]，builder 完全可控——
///   drag/armed：拉距驱动的水滴在顶部成形（复用 `dropletPath`，拉距越深
///   越鼓）；refresh：渲染 [AppLoading.inline]（加载中内容必须是规范加载
///   件，NEVER DO #7：不新画第三种加载规格）；done：水滴随回缩收小 +
///   150ms 淡出（经 [AppMetrics.reduceMotionOf] 归零）。
///   Cupertino 控件依赖 overscroll 物理（ClampingScrollPhysics 下无法触发，
///   见其 API 文档），sliver 路线强制
///   `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())`——
///   Android 侧滚动手感从 clamp+glow 变为弹性回弹，这是 sliver 路线的前提。
/// - **box 降级路线**（其余滚动视口，sliver 化成本过高时）：包品牌色
///   [RefreshIndicator] 消灭 Material 蓝转圈；这是全库唯一允许出现
///   `RefreshIndicator` 的降级路径。
///
/// 复制 `CustomScrollView` 时逐字段转发构造参数（已废弃的 cacheExtent 除外，
/// 页面侧用 scrollCacheExtent）；页面给 CustomScrollView 新增参数时这里需要
/// 同步转发。
class AppPullRefresh extends StatefulWidget {
  /// 供测试定位 armed/done 态的水滴。
  static const Key dropletKey = ValueKey<String>('AppPullRefresh.droplet');

  /// 触发距离（design.md §3.1：≈70pt 对齐旧 RefreshIndicator 手感）。
  static const double triggerPullDistance = 70;

  /// 刷新中保底占位高度：容纳 `AppLoading.inline`（占地 46×35）。
  static const double indicatorExtent = 60;

  const AppPullRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  /// 刷新回调：拉距越过 [triggerPullDistance] 后松手时调用。
  final Future<void> Function() onRefresh;

  /// 滚动视口：`CustomScrollView` 走 sliver 路线，其余走降级路线。
  final Widget child;

  @override
  State<AppPullRefresh> createState() => _AppPullRefreshState();
}

class _AppPullRefreshState extends State<AppPullRefresh> {
  @override
  Widget build(BuildContext context) {
    final Widget child = widget.child;
    if (child is CustomScrollView) {
      return _buildSliverRoute(child);
    }
    // box 滚动降级路线：品牌色 RefreshIndicator（全库唯一出现处）。
    final AppTokens tokens = context.app;
    return RefreshIndicator(
      color: tokens.colors.brand,
      backgroundColor: tokens.colors.surface1,
      onRefresh: widget.onRefresh,
      child: child,
    );
  }

  /// sliver 路线：复制 CustomScrollView 并预置刷新控件。
  Widget _buildSliverRoute(CustomScrollView scroll) {
    return CustomScrollView(
      key: scroll.key,
      scrollDirection: scroll.scrollDirection,
      reverse: scroll.reverse,
      controller: scroll.controller,
      primary: scroll.primary,
      // CupertinoSliverRefreshControl 在 ClampingScrollPhysics 下无法触发
      // （见其 API 文档），sliver 路线强制 overscrolling 物理。
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      scrollBehavior: scroll.scrollBehavior,
      shrinkWrap: scroll.shrinkWrap,
      center: scroll.center,
      anchor: scroll.anchor,
      scrollCacheExtent: scroll.scrollCacheExtent,
      semanticChildCount: scroll.semanticChildCount,
      dragStartBehavior: scroll.dragStartBehavior,
      keyboardDismissBehavior: scroll.keyboardDismissBehavior,
      restorationId: scroll.restorationId,
      clipBehavior: scroll.clipBehavior,
      hitTestBehavior: scroll.hitTestBehavior,
      slivers: <Widget>[
        CupertinoSliverRefreshControl(
          refreshTriggerPullDistance: AppPullRefresh.triggerPullDistance,
          refreshIndicatorExtent: AppPullRefresh.indicatorExtent,
          onRefresh: widget.onRefresh,
          builder: _buildIndicator,
        ),
        ...scroll.slivers,
      ],
    );
  }

  /// builder 状态机：drag/armed = 拉距水滴，refresh = AppLoading.inline，
  /// done = 水滴回吸消失。
  ///
  /// [AnimatedOpacity] 在四个非 inactive 态常驻同一树位（隐式动画元素跨态
  /// 存活）：refresh→done 切换时才能从 1 淡到 0，而不是重挂载后瞬隐。
  Widget _buildIndicator(
    BuildContext context,
    RefreshIndicatorMode mode,
    double pulledExtent,
    double triggerDistance,
    double indicatorExtent,
  ) {
    switch (mode) {
      case RefreshIndicatorMode.inactive:
        return const SizedBox.shrink();

      case RefreshIndicatorMode.drag:
      case RefreshIndicatorMode.armed:
      case RefreshIndicatorMode.refresh:
      case RefreshIndicatorMode.done:
        final bool collapsing = mode == RefreshIndicatorMode.done;
        final bool refreshing = mode == RefreshIndicatorMode.refresh;
        final double t = (pulledExtent / triggerDistance).clamp(0.0, 1.0);
        final AppMetrics m = context.app.metrics;
        return AnimatedOpacity(
          // drag/armed/refresh 恒 1（目标不变，隐式动画不会逐帧重跑）；仅
          // done 切到 0：150ms hover 档淡出（回吸），reduceMotion 归零。
          opacity: collapsing ? 0.0 : 1.0,
          duration: collapsing
              ? AppMetrics.reduceMotionOf(context, m.hover)
              : Duration.zero,
          child: Align(
            alignment: refreshing ? Alignment.center : Alignment.bottomCenter,
            child: Padding(
              padding: refreshing
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(bottom: 6),
              child: refreshing
                  // 加载中：规范加载件（NEVER DO #7），不新画一种加载规格。
                  ? const AppLoading.inline()
                  : Transform.scale(
                      // 拉距越深越鼓：宽度先起、高度跟上；done 随回缩收小。
                      scaleX: 0.25 + 0.75 * t,
                      scaleY: 0.40 + 0.60 * t,
                      alignment: Alignment.bottomCenter,
                      child: CustomPaint(
                        key: AppPullRefresh.dropletKey,
                        size: const Size(22, 30),
                        painter: _DropletPainter(
                          color: context.app.colors.brand,
                        ),
                      ),
                    ),
            ),
          ),
        );
    }
  }
}

/// 水滴 painter：复用 [dropletPath]（JellyProgressThumb 同源形状），填充
/// 品牌色 + 左上白色 specular（高光有先例：JellyProgressThumb）。
class _DropletPainter extends CustomPainter {
  const _DropletPainter({required this.color});

  /// 水滴本体色（品牌色，由 builder 侧从 Token 取）。
  final Color color;

  /// 水滴静止半径（包络 22×30：宽 1.84r、高 2.65r）。
  static const double _r = 11;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final Path path = dropletPath(_r);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawCircle(
      Offset(-_r * 0.35, -_r * 0.45),
      _r * 0.22,
      Paint()..color = Colors.white.withValues(alpha: 0.4),
    );
  }

  @override
  bool shouldRepaint(_DropletPainter oldDelegate) => oldDelegate.color != color;
}
