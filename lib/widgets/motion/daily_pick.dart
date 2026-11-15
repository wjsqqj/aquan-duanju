import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../models/models.dart';
import '../common.dart';
import '../ui/app_badge.dart';
import '../ui/app_icons.dart';
import '../ui/app_section.dart';
import 'fx_curves.dart';

// =============================================================================
// 每日推荐揭幕 section（effect-atlas fullscreen-chapter-reveal 移植 · E6）
//
// scrim 取舍（DESIGN.md §7）：文字保护型 scrim 渐变**不在**白名单（白名单
// 三处全是品牌光晕，无一用于压暗文字底），所以内容行底走**实色阶梯**——
// 主行实色 canvas@0.62 + 上缘一条 12px 的 canvas@0.28 过渡带，两段实色
// 分层而非线性渐变，不新增白名单外渐变。
//
// 视差行程取刻度内 s64（PRD 写 72px 内，64 ≤ 72 cap，刻度外 18/72px 不入
// 布局）；标签升距取 s16（刻度外 18px 的最近刻度）。
// =============================================================================

/// 每日推荐揭幕窗（atlas fullscreen-chapter-reveal：裁开 + 前缘线 + 视差 +
/// 标签交叉淡入，900ms cap 内）。kit 级 dartdoc 常量，挂 DESIGN.md §6 编排
/// 豁免（进场编排），不另占五档。
const Duration fxDailyReveal = Duration(milliseconds: 900);

/// 封面视差量（s64 刻度，≤72px cap）。
const double _kParallaxSpan = 64;

/// 内容行底（实色第一阶：canvas @0.62）。
const double _kScrimMainAlpha = 0.62;

/// 过渡带（实色第二阶：canvas @0.28，高 s12）。
const double _kScrimStepAlpha = 0.28;

/// 揭示进度里内容行开始交叉淡入的位置（atlas 规格 58%）。
const double _kLabelRiseStart = 0.58;

/// 按日期种子从候选里确定性选一部（PRD：`dayOfYear % min(n, 12)`）。
///
/// 同一天必然同一结果；items 为空返回 null（section 不渲染）。
T? dailyPickOf<T>(List<T> items, DateTime now) {
  if (items.isEmpty) return null;
  final int dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
  return items[dayOfYear % math.min(items.length, 12)];
}

/// 每日推荐 section（发现页，插在历史 rail 之后、频道条之前）。
///
/// 全宽 16:9 封面卡 + 实色阶梯 scrim + 「今日推荐」徽标 + 剧名 + 元数据 +
/// 去看入口；首次滚入视口（≥40% 可见）播一次揭幕（底边向上裁开 + 前缘
/// brand 线 + 封面视差 + 内容 58% 处交叉淡入），一次性由调用方经
/// [onRevealedOnce] 记账（每会话每 tab 一次），已揭过的经 [revealed]
/// 静态直出。「减少动效」静态直出。点整卡 = [onOpen]（openDetail）。
class FxDailyPick extends StatefulWidget {
  const FxDailyPick({
    super.key,
    required this.item,
    required this.onOpen,
    this.revealed = false,
    this.onRevealedOnce,
  });

  final SeriesSummary item;

  /// 整卡点击（openDetail）。
  final VoidCallback onOpen;

  /// true = 该 tab 本会话已揭过（静态直出，不重播）。
  final bool revealed;

  /// 揭幕起跑时回调一次（调用方把 tab 记进内存集合）。
  final VoidCallback? onRevealedOnce;

  @override
  State<FxDailyPick> createState() => _FxDailyPickState();
}

class _FxDailyPickState extends State<FxDailyPick>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: fxDailyReveal,
  );

  bool _wired = false;
  bool _listening = false;
  bool _started = false;
  bool _measureScheduled = false;
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    if (widget.revealed || AppMetrics.reduceMotionEnabled(context)) {
      // 已揭过 / reduceMotion：静态直出（t=1 与揭完逐像素一致）。
      _controller.value = 1;
      _started = true;
      return;
    }
    // 首次滚入视口检测：监听外层滚动位置 + 首帧先查一次（构建时已在
    // 视口内的场景）。Scrollable.maybeOf 拿的是最近的外层滚动视口，
    // 不引入第二滚动视口、也不要求调用方传 controller。
    _attachPosition();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
  }

  void _attachPosition() {
    if (_listening) return;
    final ScrollPosition? position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    _position = position;
    position.addListener(_checkVisible);
    _listening = true;
  }

  /// ≥40% 可见时起跑（一次性；滚动往返不重播）。
  ///
  /// 滚动通知在 layout 之前派发，`localToGlobal` 当帧还是旧几何——测量
  /// 统一推到帧末（每帧至多排一次，起跑后短路）。
  void _checkVisible() {
    if (_started || _measureScheduled || !mounted) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measure();
    });
  }

  void _measure() {
    if (_started || !mounted) return;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.height <= 0) return;
    final Rect bounds = box.localToGlobal(Offset.zero) & box.size;
    // 可见性基准取外层滚动视口（sliver 内容在窗口内只是其中一段）；
    // 无外层滚动视口（直挂 body）退回窗口尺寸。
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    final RenderBox? viewportBox =
        scrollable?.context.findRenderObject() as RenderBox?;
    final Rect screen = viewportBox != null
        ? viewportBox.localToGlobal(Offset.zero) & viewportBox.size
        : Offset.zero & MediaQuery.sizeOf(context);
    final double visible = bounds.intersect(screen).height;
    if (visible < box.size.height * 0.4) return;
    _started = true;
    _detachPosition();
    widget.onRevealedOnce?.call();
    _controller.forward(from: 0);
  }

  void _detachPosition() {
    if (!_listening) return;
    _position?.removeListener(_checkVisible);
    _position = null;
    _listening = false;
  }

  @override
  void dispose() {
    _detachPosition();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final DateTime now = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(title: '今日推荐', subtitle: '${now.month}月${now.day}日'),
        Padding(
          padding: EdgeInsets.fromLTRB(m.s12, 0, m.s12, m.s8),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final double t = _controller.value;
                final double reveal = Fx.glide.transform(t);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onOpen,
                  child: ClipRRect(
                    borderRadius: BorderRadius.all(Radius.circular(m.radiusMd)),
                    child: ClipRect(
                      clipper: _RiseClipper(reveal),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 封面视差：裁开的同时图向下沉 64px→0 + 1.025→1。
                          Transform.translate(
                            offset: Offset(0, (1 - reveal) * _kParallaxSpan),
                            child: Transform.scale(
                              scale: 1.025 - 0.025 * reveal,
                              child: CoverImage(url: widget.item.coverUrl),
                            ),
                          ),
                          // 前缘 brand 线骑在裁开前沿上，揭完随行消失。
                          // 前沿在「1-t」高度处（自底向上），对齐到该边。
                          if (reveal < 1)
                            Align(
                              alignment: Alignment(0, 1 - reveal * 2),
                              child: Container(
                                height: m.focusRing,
                                color: tokens.colors.brand,
                              ),
                            ),
                          _buildContent(context, reveal),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 实色阶梯 scrim + 内容行（58% 处交叉淡入升 s16）。
  Widget _buildContent(BuildContext context, double reveal) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final double labelT = Fx.glide.transform(
      ((reveal - _kLabelRiseStart) / (1 - _kLabelRiseStart)).clamp(0.0, 1.0),
    );
    if (labelT <= 0) return const SizedBox.shrink();
    final SeriesSummary item = widget.item;
    final String? meta = _metaLine(item);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 实色第二阶（过渡带，无渐变——§7 白名单外）。
          Opacity(
            opacity: labelT,
            child: Container(
              height: m.s12,
              color: tokens.colors.canvas.withValues(alpha: _kScrimStepAlpha),
            ),
          ),
          // 实色第一阶（内容行主底）。
          ColoredBox(
            color: tokens.colors.canvas.withValues(alpha: _kScrimMainAlpha),
            child: Opacity(
              opacity: labelT,
              child: Transform.translate(
                offset: Offset(0, (1 - labelT) * m.s16),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(m.s16, m.s8, m.s16, m.s12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    spacing: m.s12,
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: m.s2,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: m.s8,
                              children: [
                                const AppBadge(text: '今日推荐'),
                                if (meta != null)
                                  Flexible(
                                    child: Text(
                                      meta,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: tokens.label.copyWith(
                                        color: tokens.colors.textSecondary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.h2.copyWith(
                                color: tokens.colors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 去看入口（openDetail 语义，不做「播放」谎称）。
                      Container(
                        padding: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, m.s8),
                        decoration: BoxDecoration(
                          color: tokens.colors.brand,
                          borderRadius: BorderRadius.all(
                            Radius.circular(m.radiusPill),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: m.s4,
                          children: [
                            Icon(
                              AppIcons.play,
                              size: m.s16,
                              color: tokens.colors.onBrand,
                            ),
                            Text(
                              '去看',
                              style: tokens.label.copyWith(
                                color: tokens.colors.onBrand,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 元数据行：分类 · 集数 · 字数按非空拼接（字段为 0/空不出现；影视数据
  /// 只有集数、书只有字数，按数据自然分层——与 SeriesCard 副标题的「共N集」
  /// 同一口径，不按类型分家）；全空返回 null。
  String? _metaLine(SeriesSummary item) {
    final List<String> parts = <String>[
      if (item.category.isNotEmpty) item.category,
      if (item.episodeCount > 0) '${item.episodeCount}集',
      if (item.words > 0) '${(item.words / 10000).toStringAsFixed(0)}万字',
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  // ---- 测试口（test/motion/daily_pick_test.dart）----

  @visibleForTesting
  double get debugRevealT => _controller.value;

  @visibleForTesting
  bool get debugStarted => _started;
}

/// 揭幕裁剪：底边向上裁开（可见区 = 底部向上生长的矩形，前缘骑 brand 线）。
class _RiseClipper extends CustomClipper<Rect> {
  const _RiseClipper(this.t);

  /// 揭示进度 0..1（1 = 全显，与无裁剪逐像素一致）。
  final double t;

  @override
  Rect getClip(Size size) {
    final double height = size.height * t.clamp(0.0, 1.0);
    return Rect.fromLTWH(0, size.height - height, size.width, height);
  }

  @override
  bool shouldReclip(_RiseClipper oldClipper) => oldClipper.t != t;
}
