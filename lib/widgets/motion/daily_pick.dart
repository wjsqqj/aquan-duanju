import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../models/models.dart';
import '../common.dart';
import '../ui/app_badge.dart';
import '../ui/app_gap.dart';
import '../ui/app_icons.dart';
import '../ui/app_section.dart';
import 'fx_curves.dart';

// =============================================================================
// 每日推荐轮播 section（effect-atlas fullscreen-chapter-reveal 移植 · E6）
//
// 11-16 改版（用户实测「一张半宽大图，右边空一片，不能左右滑」）：
// 改成腾讯视频式**横向轮播**——整行宽封面 + 左右箭头 + 指示点 + 悬停暂停的
// 自动轮播 + 桌面鼠标拖拽。
//
// 文案**移出封面**（原先压在封面上的实色 scrim 条被反馈「很丑」）：封面下方
// 独立一行放徽标/剧名/元数据/去看入口，既不再遮图，也不需要文字保护型
// 渐变（DESIGN.md §7 白名单外）。
// =============================================================================

/// 每日推荐揭幕窗（atlas fullscreen-chapter-reveal：裁开 + 前缘线 + 视差 +
/// 标签交叉淡入，900ms cap 内）。kit 级 dartdoc 常量，挂 DESIGN.md §6 编排
/// 豁免（进场编排），不另占五档。
const Duration fxDailyReveal = Duration(milliseconds: 900);

/// 自动轮播间隔（悬停时暂停）。
const Duration fxDailyAutoPlay = Duration(seconds: 7);

/// 轮播候选条数上限（多给几张，左右能滑）。
const int kDailyPickMaxItems = 6;

/// 封面视差量（s64 刻度，≤72px cap）。
const double _kParallaxSpan = 64;

/// 轮播封面的**最大渲染宽度**（逻辑像素）。
///
/// 上游封面约 1200px 宽：全窗铺满（1920+）会把图放大 1.6 倍、观感发糊；
/// 但限得比窗口窄（旧值 880/1440）又会在列里留一条空白、被反馈「没铺满
/// 整列」。1600 覆盖到常见 2K 窗口，超宽屏才留边。
const double kDailyPickMaxWidth = 1600;

/// 封面区高宽比（宽 → 高）。16:9 太扁，0.42 接近站点 banner。
const double _kCarouselHeightRatio = 0.42;

/// 封面区高度上限 / 下限（逻辑像素）。
const double _kCarouselMaxHeight = 460;
const double _kCarouselMinHeight = 180;

/// 宽屏阈值：达到才叠信息卡 + 出缩略图切换条（窄屏放不下）。
const double _kWideLayoutWidth = 720;

/// 信息卡最大宽度 / 占整块宽度比例。
///
/// 0.38/300 时左侧介绍只占三分之一、两侧又各被箭头列吃掉 48，被反馈
/// 「两边留白太多、介绍那块太小」。现在介绍约占四成，箭头列也收窄到 32。
const double _kInfoCardWidth = 520;
const double _kInfoCardRatio = 0.42;

/// 缩略图切换条：条高、单卡宽、封面高。
const double _kThumbStripHeight = 104;
const double _kThumbWidth = 128;
const double _kThumbCoverHeight = 72;

/// 宽版左右切换按钮的**按钮直径**，也是列宽基数。
///
/// 演进史：40 圆钮 → 32（太小）→ 贯通整高导轨（更丑）→ 48 圆钮 → **56**。
/// 列宽 = 本值 + 页边 s12，圆钮在这段空白里居中——既居中又不贴边，
/// 而且腾出的空间正好让圆钮做得更大。
const double _kArrowSlot = 80;

/// 切换圆钮直径。
const double _kArrowDot = 80;

/// 宽版整块高度区间（信息卡与封面同高）。
const double _kWideMinHeight = 220;
const double _kWideMaxHeight = 420;

/// 揭示进度里文案行开始交叉淡入的位置（atlas 规格 58%）。
const double _kLabelRiseStart = 0.58;

/// 起跑阈值：与滚动视口有 ≥15% 交集就揭（露头即揭；旧值 40% 在新版更高的
/// 版式下容易永远达不到，表现就是「第一次打开今日推荐是空白」）。
const double _kRevealVisibleRatio = 0.15;

/// 按日期种子从候选里确定性选一部（PRD：`dayOfYear % min(n, 12)`）。
///
/// 同一天必然同一结果；items 为空返回 null（section 不渲染）。
T? dailyPickOf<T>(List<T> items, DateTime now) {
  if (items.isEmpty) return null;
  final int dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
  return items[dayOfYear % math.min(items.length, 12)];
}

/// 今日推荐轮播的候选序列：以当日种子为**首位**，向后顺延 [count] 条
/// （循环取，候选不足就少给）。
///
/// 保留 [dailyPickOf] 的「同一天首张固定」语义，同时给轮播提供可滑动的
/// 其余条目——用户左右滑动时看到的是同一批头部候选。
List<T> dailyPickItemsOf<T>(
  List<T> items,
  DateTime now, {
  int count = kDailyPickMaxItems,
}) {
  if (items.isEmpty || count <= 0) return const <Never>[];
  final List<T> head = items
      .take(math.min(items.length, 12))
      .toList(growable: false);
  final int dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
  final int start = dayOfYear % head.length;
  final int n = math.min(count, head.length);
  return <T>[for (var i = 0; i < n; i++) head[(start + i) % head.length]];
}

/// 每日推荐 section（发现页，插在历史 rail 之后、频道条之前）。
///
/// 整行宽的横向轮播：大封面 + 左右箭头 + 指示点；封面下方一行文案（徽标 ·
/// 剧名 · 元数据 · 去看）。悬停暂停自动轮播（[fxDailyAutoPlay]），桌面可
/// 鼠标拖拽。首次滚入视口（≥40% 可见）播一次揭幕（底边向上裁开 + 前缘
/// brand 线 + 封面视差 + 文案 58% 处淡入），一次性由调用方经 [onRevealedOnce]
/// 记账；已揭过的经 [revealed] 静态直出。「减少动效」静态直出且不自动轮播。
/// 点卡片 = [onOpen]（openDetail）。
class FxDailyPick extends StatefulWidget {
  const FxDailyPick({
    super.key,
    required this.items,
    required this.onOpen,
    this.revealed = false,
    this.onRevealedOnce,
  });

  /// 轮播候选（首位 = 今日推荐；空列表时调用方不渲染本 section）。
  final List<SeriesSummary> items;

  /// 点某张卡（openDetail）。
  final ValueChanged<SeriesSummary> onOpen;

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

  final PageController _pager = PageController();

  Timer? _autoPlay;

  /// 揭幕兜底计时器：到点还没起跑就直接揭（防「首屏空白卡片」）。
  Timer? _revealFallback;

  int _index = 0;
  bool _hovering = false;

  bool _wired = false;
  bool _listening = false;
  bool _started = false;
  bool _measureScheduled = false;
  int _measureRetries = 0;
  ScrollPosition? _position;

  SeriesSummary? get _current =>
      widget.items.isEmpty ? null : widget.items[_index];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    if (widget.revealed || AppMetrics.reduceMotionEnabled(context)) {
      // 已揭过 / reduceMotion：静态直出（t=1 与揭完逐像素一致）。
      _controller.value = 1;
      _started = true;
      _scheduleAutoPlay();
      return;
    }
    // 首次滚入视口检测：监听外层滚动位置 + 首帧先查一次（构建时已在
    // 视口内的场景）。Scrollable.maybeOf 拿的是最近的外层滚动视口，
    // 不引入第二滚动视口、也不要求调用方传 controller。
    _attachPosition();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
    // 兜底：可见性测量一旦错过（布局时序 / 没挂上滚动监听 / 首屏只露一半），
    // 组件就停在裁剪高度 0 的「空白卡片」上——用户实测「第一次打开今日推荐
    // 是空白的」。1.5s 还没起跑就直接揭，宁可少一次仪式感也不留白。
    _revealFallback?.cancel();
    _revealFallback = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || _started) return;
      _startReveal();
    });
  }

  @override
  void didUpdateWidget(FxDailyPick old) {
    super.didUpdateWidget(old);
    if (old.items.length != widget.items.length) {
      _index = _index.clamp(0, math.max(0, widget.items.length - 1));
      _scheduleAutoPlay();
    }
  }

  void _attachPosition() {
    if (_listening) return;
    final ScrollPosition? position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    _position = position;
    position.addListener(_checkVisible);
    _listening = true;
  }

  /// 露头（≥15%）即起跑（一次性；滚动往返不重播）。
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
    if (box == null || !box.hasSize || box.size.height <= 0) {
      // 首帧可能还没布局完（数据到达那一帧）：排到下一帧再看，别把测量
      // 机会用掉就再也不管了。
      if (_measureRetries < 3) {
        _measureRetries++;
        _checkVisible();
      }
      return;
    }
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
    if (visible < box.size.height * _kRevealVisibleRatio) return;
    _startReveal();
  }

  /// 起跑揭幕（幂等）。可见性测量与兜底计时器共用，避免两套起跑逻辑。
  void _startReveal() {
    if (_started || !mounted) return;
    _started = true;
    _revealFallback?.cancel();
    _revealFallback = null;
    _detachPosition();
    widget.onRevealedOnce?.call();
    _controller.forward(from: 0);
    _scheduleAutoPlay();
  }

  /// 自动轮播：揭幕完才起跑；悬停 / 只剩一张 / reduceMotion 时不动。
  void _scheduleAutoPlay() {
    _autoPlay?.cancel();
    _autoPlay = null;
    if (widget.items.length < 2) return;
    if (!_started || !mounted) return;
    if (AppMetrics.reduceMotionEnabled(context)) return;
    _autoPlay = Timer.periodic(fxDailyAutoPlay, (_) {
      if (!mounted || _hovering || !_pager.hasClients) return;
      _goTo((_index + 1) % widget.items.length);
    });
  }

  void _goTo(int page) {
    if (!_pager.hasClients) return;
    _pager.animateToPage(
      page,
      duration: const Duration(milliseconds: 420),
      curve: Fx.glide,
    );
  }

  void _detachPosition() {
    if (!_listening) return;
    _position?.removeListener(_checkVisible);
    _position = null;
    _listening = false;
  }



  @override
  void dispose() {
    _autoPlay?.cancel();
    _revealFallback?.cancel();
    _detachPosition();
    _pager.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final DateTime now = DateTime.now();
    final SeriesSummary? current = _current;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(title: '今日推荐', subtitle: '${now.month}月${now.day}日'),
        Padding(
          padding: EdgeInsets.only(bottom: m.s8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 整行宽（上限 1600）：不再限成半宽留一片空白。
              final double available =
                  math.min(constraints.maxWidth, kDailyPickMaxWidth);
              // 宽屏走爱奇艺式：左信息卡 / 右封面，切换钮落在两侧空白正中。
              // 窄屏放不下信息卡，退回「封面 + 下方一行文案」。
              final bool wide = available >= _kWideLayoutWidth;
              // 宽版让箭头列自己当页边距（圆钮才能在「页边→卡片」那段空白里
              // 居中）；窄版仍留 s12 页边。
              final double width = wide ? available : available - m.s12 * 2;
              final double imageHeight = (width * _kCarouselHeightRatio)
                  .clamp(_kCarouselMinHeight, _kCarouselMaxHeight)
                  .toDouble();
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints.tightFor(width: width),
                  // 封面与文案都要跟着揭幕进度走，所以 AnimatedBuilder 必须
                  // 罩住整块——只罩封面时文案行永远停在 opacity 0。
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final double reveal =
                          Fx.glide.transform(_controller.value);
                      if (wide) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildWideBlock(
                              context,
                              width: width,
                              reveal: reveal,
                              current: current,
                            ),
                            if (widget.items.length > 1)
                              _buildThumbStrip(context),
                          ],
                        );
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildCoverArea(
                            context,
                            width: width,
                            height: imageHeight,
                            reveal: reveal,
                          ),
                          if (current != null) _buildInfoRow(context, current),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 宽屏信息卡（爱奇艺式）：徽标 + 榜单/热度 + 剧名 + 标签 + 元数据 + 简介
  /// + 去看。卡在封面左上，高度撑满上下留白；内容超高时卡内滚动，不撑破。
  Widget _buildInfoCard(
    BuildContext context,
    SeriesSummary item,
    double reveal,
  ) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final double t = Fx.glide.transform(
      ((reveal - _kLabelRiseStart) / (1 - _kLabelRiseStart)).clamp(0.0, 1.0),
    );
    final String tags = item.tags
        .where((tag) => tag.trim().isNotEmpty)
        .take(3)
        .join(' · ');
    final String? meta = _metaLine(item);
    final String? stat = item.playCount > 0
        ? '播放 ${formatCount(item.playCount)}'
        : (item.heat > 0 ? '热度 ${formatCount(item.heat)}' : null);
    final TextStyle sub = tokens.label.copyWith(
      color: tokens.colors.textSecondary,
    );
    return IgnorePointer(
      ignoring: t <= 0.01,
      child: Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * m.s16),
          child: Container(
            decoration: BoxDecoration(
              // 半透明白/深面板：浅色主题接近爱奇艺的白卡，深色主题自动收成
              // 深底，都压在封面上也读得清。
              color: tokens.colors.surface3.withValues(alpha: 0.94),
              borderRadius: BorderRadius.all(Radius.circular(m.radiusLg)),
            ),
            padding: EdgeInsets.fromLTRB(m.s16, m.s16, m.s16, m.s16),
            child: Column(
              // 撑满整块高度：简介在中间伸缩，「去看」压在卡底。
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const AppBadge(text: '今日推荐'),
                    if (stat != null) ...[
                      AppGap.h(AppGapSize.s8),
                      Flexible(
                        child: Text(
                          stat,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sub,
                        ),
                      ),
                    ],
                  ],
                ),
                AppGap.v(AppGapSize.s8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.h2.copyWith(
                            color: tokens.colors.textPrimary,
                          ),
                        ),
                        if (tags.isNotEmpty) ...[
                          AppGap.v(AppGapSize.s6),
                          Text(tags, maxLines: 2, overflow: TextOverflow.ellipsis, style: sub),
                        ],
                        if (meta != null) ...[
                          AppGap.v(AppGapSize.s4),
                          Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: sub),
                        ],
                        if (item.description.trim().isNotEmpty) ...[
                          AppGap.v(AppGapSize.s8),
                          Text(
                            item.description.trim(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.label.copyWith(
                              color: tokens.colors.textTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                AppGap.v(AppGapSize.s8),
                _buildGoButton(context, item),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「去看」胶囊（openDetail 语义，不做「播放」谎称）。
  Widget _buildGoButton(BuildContext context, SeriesSummary item) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(item),
      child: Container(
        padding: EdgeInsets.fromLTRB(m.s16, m.s8, m.s16, m.s8),
        decoration: BoxDecoration(
          color: tokens.colors.brand,
          borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: m.s4,
          children: [
            Icon(AppIcons.play, size: m.s16, color: tokens.colors.onBrand),
            Text(
              '去看',
              style: tokens.label.copyWith(color: tokens.colors.onBrand),
            ),
          ],
        ),
      ),
    );
  }

  /// 封面下方的缩略图切换条：当前项 brand 描边 + 不降透明，其余压暗。
  Widget _buildThumbStrip(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(height: _kThumbStripHeight),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // 与上方的「箭头列 + 信息卡」对齐：左右各让出箭头列宽度。
        padding: EdgeInsets.only(
          top: m.s8,
          left: widget.items.length > 1 ? _kArrowSlot + m.s24 : 0,
          right: widget.items.length > 1 ? _kArrowSlot + m.s24 : 0,
        ),
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => AppGap.h(AppGapSize.s8),
        itemBuilder: (context, i) {
          final SeriesSummary item = widget.items[i];
          final bool active = i == _index;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _goTo(i),
            child: ConstrainedBox(
              constraints: BoxConstraints.tightFor(width: _kThumbWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: _kThumbCoverHeight,
                    decoration: BoxDecoration(
                      borderRadius:
                          BorderRadius.all(Radius.circular(m.radiusSm)),
                      // 非选中项边框靠 brand 的 alpha=0 隐形（色值审计只认 token）。
                      border: Border.all(
                        color: tokens.colors.brand
                            .withValues(alpha: active ? 1 : 0),
                        width: m.focusRing,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Opacity(
                      opacity: active ? 1 : 0.72,
                      child: CoverImage(url: item.coverUrl),
                    ),
                  ),
                  AppGap.v(AppGapSize.s4),
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.label.copyWith(
                      color: active
                          ? tokens.colors.textPrimary
                          : tokens.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 宽版整块：`[箭头列][信息卡][封面][箭头列]`。
  ///
  /// 信息卡**不再压在封面上**（用户实测：封面被挡住、图又太大），改成左侧
  /// 独立一栏；切换箭头落在两侧列内空白，不遮图。
  Widget _buildWideBlock(
    BuildContext context, {
    required double width,
    required double reveal,
    required SeriesSummary? current,
  }) {
    final double height = (width * 0.34)
        .clamp(_kWideMinHeight, _kWideMaxHeight)
        .toDouble();
    // 卡宽随列宽收：窄列时按比例让位给封面。
    final double cardWidth =
        math.min(_kInfoCardWidth, width * _kInfoCardRatio).toDouble();
    final bool showArrows = widget.items.length > 1;
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(height: height),
      child: ClipRect(
        clipper: _RiseClipper(reveal),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showArrows) _buildArrowSlot(context, left: true),
            if (current != null)
              ConstrainedBox(
                constraints: BoxConstraints.tightFor(width: cardWidth),
                child: _buildInfoCard(context, current, reveal),
              ),
            AppGap.h(AppGapSize.s12),
            Expanded(
              child: _buildCoverBox(context, reveal: reveal, withArrows: false),
            ),
            if (showArrows) _buildArrowSlot(context, left: false),
          ],
        ),
      ),
    );
  }

  /// 切换按钮：列内垂直居中的大圆钮（不压封面）。
  ///
  /// 列宽 = 圆钮 + 两侧各 s12；圆钮在其中居中 → 距页边与距卡片各 12dp。
  Widget _buildArrowSlot(BuildContext context, {required bool left}) {
    if (widget.items.length < 2) return const SizedBox.shrink();
    final double slot = _kArrowSlot + context.app.metrics.s24;
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(width: slot),
      child: Center(
        child: _ArrowDot(
          left: left,
          onTap: () => _goTo(
            left
                ? (_index - 1 + widget.items.length) % widget.items.length
                : (_index + 1) % widget.items.length,
          ),
        ),
      ),
    );
  }

  /// 窄版封面区：封面 + 内嵌箭头 + 指示点 + 揭幕裁剪。
  Widget _buildCoverArea(
    BuildContext context, {
    required double width,
    required double height,
    required double reveal,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(width: width, height: height),
      child: ClipRect(
        clipper: _RiseClipper(reveal),
        child: _buildCoverBox(context, reveal: reveal, withArrows: true),
      ),
    );
  }

  /// 封面本体：圆角 + 轮播 + 指示点 + 计数器（[withArrows] 时箭头内嵌）。
  Widget _buildCoverBox(
    BuildContext context, {
    required double reveal,
    required bool withArrows,
  }) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final int count = widget.items.length;
    return MouseRegion(
      onEnter: (_) => _hovering = true,
      onExit: (_) {
        _hovering = false;
        // 悬停期间可能正好跨过自动轮播点，回到不悬停时重新计时。
        _scheduleAutoPlay();
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(m.radiusLg)),
          color: tokens.colors.surface2,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 横向拖拽：桌面默认不认鼠标拖拽，这里放开。
            ScrollConfiguration(
              behavior: const _HorizontalDragBehavior(),
              child: PageView.builder(
                controller: _pager,
                itemCount: count,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) =>
                    _buildCover(context, widget.items[i], reveal: reveal),
              ),
            ),
            // 前缘 brand 线骑在裁开前沿上，揭完随行消失。
            if (reveal < 1)
              Align(
                alignment: Alignment(0, 1 - reveal * 2),
                child: Container(
                  height: m.focusRing,
                  color: tokens.colors.brand,
                ),
              ),
            if (count > 1) ...[
              if (withArrows) ...[
                _buildArrow(context, left: true, inset: m.s12),
                _buildArrow(context, left: false, inset: m.s12),
              ],
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: m.s12),
                  child: _buildDots(context),
                ),
              ),
              Positioned(
                right: m.s12,
                top: m.s12,
                child: _buildCounter(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单张封面：视差 + 点开详情。
  Widget _buildCover(
    BuildContext context,
    SeriesSummary item, {
    required double reveal,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(item),
      child: Transform.translate(
        offset: Offset(0, (1 - reveal) * _kParallaxSpan),
        child: Transform.scale(
          scale: 1.025 - 0.025 * reveal,
          // 大幅拉伸时用双三次插值，减轻放大后的锯齿。
          child: CoverImage(
            url: item.coverUrl,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }

  /// 封面下方的文案行：徽标 · 剧名（两行 + tooltip）· 元数据 · 去看。
  Widget _buildInfoRow(BuildContext context, SeriesSummary item) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final double labelT = Fx.glide.transform(
      ((Fx.glide.transform(_controller.value) - _kLabelRiseStart) /
              (1 - _kLabelRiseStart))
          .clamp(0.0, 1.0),
    );
    final String? meta = _metaLine(item);
    // 位置常驻、只淡入：早退会让整段高度在揭幕中途跳一下（下面内容跟着抖）。
    return IgnorePointer(
      ignoring: labelT <= 0.01,
      child: Opacity(
        opacity: labelT,
        child: Transform.translate(
          offset: Offset(0, (1 - labelT) * m.s8),
          child: Padding(
            padding: EdgeInsets.fromLTRB(m.s4, m.s8, m.s4, m.s4),
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
                      Tooltip(
                        message: item.title,
                        waitDuration: const Duration(milliseconds: 400),
                        child: Text(
                          item.title,
                          // 两行：长剧名不再只露「…」。
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.h2.copyWith(
                            color: tokens.colors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _buildGoButton(context, item),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCounter(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Container(
      padding: EdgeInsets.fromLTRB(m.s8, m.s2, m.s8, m.s2),
      decoration: BoxDecoration(
        color: tokens.colors.canvas.withValues(alpha: 0.55),
        borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
      ),
      child: Text(
        '${_index + 1}/${widget.items.length}',
        style: tokens.micro.copyWith(color: tokens.colors.textPrimary),
      ),
    );
  }

  /// 切换箭头。[inset] 是贴边内缩：窄版内嵌在封面上时给 s12，宽版放在
  /// 外侧列里时给 0（列宽已经隔离出空白，再内缩会顶出列）。
  Widget _buildArrow(BuildContext context, {required bool left, double inset = 0}) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    if (widget.items.length < 2) return const SizedBox.shrink();
    return Align(
      alignment: left ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(
          left: left ? inset : 0,
          right: left ? 0 : inset,
        ),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _goTo(
              left
                  ? (_index - 1 + widget.items.length) % widget.items.length
                  : (_index + 1) % widget.items.length,
            ),
            child: Container(
              width: m.s40,
              height: m.s40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tokens.colors.canvas.withValues(alpha: 0.52),
                shape: BoxShape.circle,
              ),
              child: Icon(
                left ? Icons.chevron_left : Icons.chevron_right,
                size: m.s24,
                color: tokens.colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 指示点：当前页拉长成短条（腾讯视频式），可点跳转。
  Widget _buildDots(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: m.s6,
      children: [
        for (var i = 0; i < widget.items.length; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _goTo(i),
            child: AnimatedContainer(
              duration: m.micro,
              curve: m.microCurve,
              width: i == _index ? m.s16 : m.s6,
              height: m.s6,
              decoration: BoxDecoration(
                color: i == _index
                    ? tokens.colors.textPrimary
                    : tokens.colors.textPrimary.withValues(alpha: 0.42),
                borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
              ),
            ),
          ),
      ],
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

  @visibleForTesting
  int get debugIndex => _index;
}

/// 宽版左右切换的大圆钮：`surface3` 实底 + hairline 描边，hover 抬起并染
/// brand 边（页面底色上必须给底，否则白图标在白底上看不见）。
class _ArrowDot extends StatefulWidget {
  const _ArrowDot({required this.left, required this.onTap});

  final bool left;
  final VoidCallback onTap;

  @override
  State<_ArrowDot> createState() => _ArrowDotState();
}

class _ArrowDotState extends State<_ArrowDot> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: m.micro,
          curve: m.microCurve,
          width: _kArrowDot,
          height: _kArrowDot,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered ? tokens.colors.surface2 : tokens.colors.surface3,
            shape: BoxShape.circle,
            border: Border.all(
              color: _hovered ? tokens.colors.brand : tokens.colors.hairline,
              width: m.hairline,
            ),
          ),
          child: Icon(
            widget.left ? Icons.chevron_left : Icons.chevron_right,
            size: m.s40,
            color: _hovered
                ? tokens.colors.brand
                : tokens.colors.textPrimary,
          ),
        ),
      ),
    );
  }
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

/// 桌面端放开鼠标拖拽（Flutter 默认 `PageView` 不认鼠标拖动）。
class _HorizontalDragBehavior extends ScrollBehavior {
  const _HorizontalDragBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };
}
