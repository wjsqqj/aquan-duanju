import 'dart:async';

import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/auto_retry.dart';
import '../core/resume_rules.dart';
import '../core/season_number.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/jelly/jelly_button.dart';
import '../widgets/back_to_top.dart';
import '../widgets/download_sheet.dart';
import '../widgets/loading.dart';
import '../widgets/motion/film_jitter.dart';
import '../widgets/motion/masthead_title.dart';
import '../widgets/motion/title_bounce.dart';
import '../widgets/tv_scope.dart';
import '../widgets/ui/app_empty_state.dart';
import '../widgets/ui/app_icons.dart';
import 'player_screen.dart';
import 'search_screen.dart';

/// SeriesCard ↔ 详情头图的 Hero 共享元素 tag（单一事实源，两端引用同一函数）。
///
/// tag 含 seriesId：不同剧不配对、同剧两端配对飞行。注意 Flutter 硬断言
/// 「同一路由子树内同 tag 只能有一个 Hero」——详情页「相关推荐」里的
/// SeriesCard 已用 `HeroMode(enabled: false)` 关闭参与，防止服务端把
/// 自身/重复 id 混进推荐流时撞断言（见 [_recommendSection]）。
String fxHeroSeriesCoverTag(String seriesId) => 'fx-hero-series-cover:$seriesId';

/// 详情页：封面头部 + 操作行 + 剧集网格 + 相关推荐。
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.seriesId,
    this.title = '',
    this.coverHint,
    this.autoplay = false,
    this.startEpisode = 0,
    this.contentType = '',
  });

  final String seriesId;
  final String title;

  /// 来源内容类型（短剧 / 漫剧 / 电影），由发现页传入并写进历史，
  /// 用于「继续观看」按分类隔离。
  final String contentType;

  /// 入口卡片封面 URL（历史「封面即骨架」遗留参数）。
  ///
  /// 加载态已改为整页加载动画、不再渲染封面；字段保留以兼容既有入口调用，
  /// 后续若恢复 Hero 落点可直接使用。
  final String? coverHint;

  /// AI / 命令行要求「直接开播」时置真：详情加载完立刻进播放器，
  /// 有观看历史就从上次那一集那一秒续播。
  final bool autoplay;

  /// 配合 autoplay：从指定集数开播（AI「看第 N 集」），0 表示智能续播。
  final int startEpisode;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Series? _series;
  final _episodes = <Episode>[];
  String _episodeCursor = '';
  bool _episodeHasMore = false;
  Recommend? _recommend;
  bool _loading = true;
  bool _loadingMoreEpisodes = false;
  Object? _error;
  bool _descExpanded = false;
  Album? _album;
  bool _didAutoplay = false;

  /// 同名搜索结果（标题去自身去重后的条目）；null = 未加载/加载中。
  List<SeriesSummary>? _sameName;

  /// 详情页主滚动控制器：给「回到顶部」用。
  final ScrollController _pageScroll = ScrollController();

  /// 标题含「第X季/部」「合集」记号的结果 → 同名系列；其余 → 同名单剧。
  static final RegExp _seasonMark =
      RegExp(r'第\s*[0-9一二三四五六七八九十]+\s*[季部]|[（(]\s*第?[0-9一二三四五六七八九十]+\s*[季部]\s*[)）]|合集');

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _pageScroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scope = AppScope.read(context);
      final api = scope.api;
      final series = await api.getSeries(widget.seriesId);
      final epPage = await api.listEpisodes(widget.seriesId);
      Recommend? recommend;
      try {
        recommend = await api.seriesRecommend(widget.seriesId);
      } catch (_) {/* 相关推荐失败不打断详情 */}
      Album? album;
      if (series.isMultiSeason && series.relatedAlbumId.isNotEmpty) {
        try {
          album = await api.seasons(widget.seriesId);
        } catch (_) {}
      }
      await scope.history.ensureLoaded();
      await scope.follows.ensureLoaded();
      if (!mounted) return;
      // 追剧的剧打开过详情即视为已看到更新，追平记录并清除提醒。
      await scope.follows.ackUpdate(widget.seriesId, series.episodeCount);
      setState(() {
        _series = series;
        _episodes
          ..clear()
          ..addAll(epPage.items);
        _episodeCursor = epPage.cursor;
        _episodeHasMore = epPage.hasMore;
        _recommend = recommend;
        _album = album;
        _loading = false;
      });
      // 同名系列不阻塞详情首帧：失败静默（入口随之隐藏）。
      unawaited(_loadSameName(series.title));
      if (widget.autoplay && !_didAutoplay && _episodes.isNotEmpty) {
        _didAutoplay = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          var (ep, start) = _resumeTarget();
          if (widget.startEpisode > 0) {
            final idx =
                _episodes.indexWhere((e) => e.number == widget.startEpisode);
            if (idx >= 0) {
              ep = _episodes[idx];
              start = Duration.zero;
            }
          }
          _play(ep, start);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreEpisodes() async {
    if (_loadingMoreEpisodes || !_episodeHasMore) return;
    _loadingMoreEpisodes = true;
    try {
      final page = await AppScope.read(context)
          .api
          .listEpisodes(widget.seriesId, cursor: _episodeCursor);
      if (!mounted) return;
      setState(() {
        _episodes.addAll(page.items);
        _episodeCursor = page.cursor;
        _episodeHasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      _loadingMoreEpisodes = false;
    }
  }

  /// 从哪一集开始播：有历史且未看完则续播。
  ///
  /// 集数一律跟历史走（含 position==0 的「用户显式跳集」意图记录）；
  /// 位置太小时从该集开头，而不是退回第 1 集。
  (Episode, Duration) _resumeTarget() {
    final scope = AppScope.read(context);
    final h = scope.history.get(widget.seriesId);
    if (h != null && !h.finished) {
      Episode target;
      try {
        target = _episodes.firstWhere((e) => e.number == h.episode);
      } catch (_) {
        target = _episodes.first;
      }
      if (h.position > 5) {
        // 回退 3 秒再起播（参考实现 resumePoint 的 position-3）：断点多半
        // 停在半句台词里，直接接上会重复半句。
        return (target, Duration(seconds: resumePositionSeconds(h.position)));
      }
      return (target, Duration.zero);
    }
    return (_episodes.first, Duration.zero);
  }

  void _play(Episode ep, Duration start) {
    final series = _series;
    if (series == null) return;
    // 转场降噪（2026-11-16）：原 FxSceneRoute 裁切线编排（黑幕 480ms +
    // 揭示 520ms，退出反放又是 1s）在进出播放器时体感卡顿，用户要求去掉。
    // 改用主题的标准短转场（Windows = ZoomPageTransitionsBuilder ≈300ms）；
    // 减少动效仍走零时长，语义不回归。
    final bool reduceMotion = AppMetrics.reduceMotionEnabled(context);
    Navigator.of(context).push(
      reduceMotion
          ? PageRouteBuilder<void>(
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (_, _, _) => _playerPage(series, ep, start),
            )
          : MaterialPageRoute<void>(
              builder: (_) => _playerPage(series, ep, start),
            ),
    );
  }

  /// 播放器路由体：[FxSceneRoute] 与 [MaterialPageRoute] 共用同一页面构造。
  Widget _playerPage(Series series, Episode ep, Duration start) =>
      PlayerScreen(
        series: series,
        episodes: _episodes,
        startIndex: _episodes.indexOf(ep),
        startAt: start,
        seasons: _album?.seasons ?? const <Season>[],
        contentType: widget.contentType,
      );

  /// 电视横屏才分栏：竖屏/手机仍然走单列，避免信息被挤成两窄条。
  bool _isTvSplit(BuildContext context) {
    if (!TvScope.isTvOf(context)) return false;
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  Widget _buildTvSplit(BuildContext context) {
    final theme = Theme.of(context);
    final AppMetrics m = context.app.metrics;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BackButton(onPressed: () => Navigator.pop(context)),
                    Expanded(
                      child: Text(
                        _series?.title ?? widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                _header(context),
                _sameNameSection(context),
                if (_recommend != null && _recommend!.items.isNotEmpty)
                  _recommendSection(context),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 6,
          child: CustomScrollView(
            controller: _pageScroll,
            slivers: [
              SliverToBoxAdapter(child: _episodeSection(context)),
              if (_album != null && _album!.seasons.length > 1)
                SliverToBoxAdapter(child: _seasonsSection(context)),
              SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.only(bottom: m.s32)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final series = _series;
    final AppMetrics m = context.app.metrics;
    return Scaffold(
      body: _loading
          ? _loadingBody(context)
          : _error != null
              ? _errorBody(context)
              : SafeArea(
                  // 电视横屏左右分栏：左侧信息/同名/推荐，右侧选集与季。
                  // 单列布局在 16:9 大屏上要滚很久才能看到剧集。
                  child: _isTvSplit(context)
                      ? _buildTvSplit(context)
                      : CustomScrollView(
                          controller: _pageScroll,
                          slivers: [
                            SliverAppBar(
                              pinned: true,
                              // 标题最多两行（长剧名不再只剩省略号）。
                              toolbarHeight: 72,
                              // 刊头标题：页顶隐藏（与 header h1 去重），
                              // 滚过 header 高度后从左向右硬边裁切揭示
                              // （E2 masthead；reduceMotion 静态全显）。
                              title: FxMastheadTitle(
                                scrollController: _pageScroll,
                                title: series?.title ?? widget.title,
                              ),
                              leading: BackButton(
                                  onPressed: () => Navigator.pop(context)),
                            ),
                            SliverToBoxAdapter(child: _header(context)),
                            SliverToBoxAdapter(child: _episodeSection(context)),
                            if (_album != null && _album!.seasons.length > 1)
                              SliverToBoxAdapter(child: _seasonsSection(context)),
                            SliverToBoxAdapter(child: _sameNameSection(context)),
                            if (_recommend != null &&
                                _recommend!.items.isNotEmpty)
                              SliverToBoxAdapter(
                                  child: _recommendSection(context)),
                            SliverToBoxAdapter(
                                child:
                                    Padding(padding: EdgeInsets.only(bottom: m.s32))),
                          ],
                        ),
                ),
      // 详情页已经有「继续播放」FAB，不能抢占插槽：回顶按钮排在它上方。
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: context.app.metrics.s12,
        children: [
          BackToTopFab(controller: _pageScroll),
          if (!_loading && _error == null && _episodes.isNotEmpty) ...[
            // E4 胶片抖动：桌面 hover 微倾放大（1.035/-1° spring）+ 内容
            // 三控制器互质周期阶梯抖动（6 帧 step-end），离开即复位。
            // 纯视觉增强层——MouseRegion/Transform 不参与手势竞技场，
            // FAB 本体的按压/悬浮语义不动；移动/TV/reduceMotion 静态透传。
            FxFilmJitter(
              child: FloatingActionButton.extended(
                onPressed: () {
                  final (ep, start) = _resumeTarget();
                  _play(ep, start);
                },
                icon: const Icon(AppIcons.play),
                // Builder 不监听 store：从播放页 back 回来时 State 还活着，
                // 历史已变（如刚跳到第 9 集）但文案停在旧值，点击与显示不一致。
                label: ListenableBuilder(
                  listenable: AppScope.read(context).history,
                  builder: (context, _) {
                    final h = AppScope.read(
                      context,
                    ).history.get(widget.seriesId);
                    // 有未看完记录就报集数（含 position==0 的跳集意图记录），
                    // 跟 _resumeTarget 的选集逻辑保持同一个真相。
                    final ep = (h != null && !h.finished)
                        ? '继续播放 第${h.episode}集'
                        : '立即播放';
                    return Text(ep);
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 加载期整页加载态：只留返回按钮 + 居中规范加载件。
  ///
  /// 旧实现是「封面即骨架」混合态（封面/标题/占位条/行内指示并存），用户
  /// 反馈视觉碎片化；改为单一加载态，避免半骨架半内容的观感。
  Widget _loadingBody(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          const Positioned.fill(child: Center(child: AppLoading())),
          Positioned(
            left: 0,
            top: 0,
            child: BackButton(onPressed: () => Navigator.pop(context)),
          ),
        ],
      ),
    );
  }

  /// 错误态整页：错误面板 + 左上常驻返回。
  ///
  /// `ErrorRetryView` 自身只有「重试 / 立即重置」，不带导航；桌面端没有系统
  /// 返回手势，出错后不给这颗按钮，用户就只能关软件（用户实测）。返回位置
  /// 与 [_loadingBody] 一致，加载→出错时按钮不会跳位。
  Widget _errorBody(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: ErrorRetryView(
              error: _error!,
              onRetry: _reload,
              // 设备被限/被拒时给「立即重置」，不必绕道「我的 → 设置」
              //（与发现/筛选页同一入口）。
              onResetDevice: deviceRecoverable(_error!)
                  ? () async {
                      final ok = await resetAnonymousDevice(context,
                          AppScope.read(context).api.resetDevice);
                      if (ok && mounted) _reload();
                    }
                  : null,
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: BackButton(onPressed: () => Navigator.pop(context)),
          ),
        ],
      ),
    );
  }

  /// 详情行的标签（InfoKind=3，服务端自带搜索 schema），可点跳搜索。
  List<String> _tags(Series series) => [
        for (final r in series.rows)
          if (r.kind == 3 && r.text.isNotEmpty) r.text,
      ];

  /// 同名搜索：以当前标题为关键词取一页结果，去掉自身后归两组
  /// （标题带季/部/合集记号 → 系列；其余 → 单剧）。
  ///
  /// 综合搜索的结果里混着帖子 / 用户 / 合集卡片（同一条 `video_data` 行
  /// 也会回传 post_data 等非剧集行），它们没有集数，拿 ID 去 `getSeries`
  /// 会命中服务端下架码 101001，详情页直接变成「该内容暂时无法观看」。
  /// 这里只保留有集数的真剧，避免把不可播放的卡片塞进同名分区。
  Future<void> _loadSameName(String title) async {
    try {
      final page = await AppScope.read(context)
          .api
          .search(title, pageSize: 30);
      if (!mounted) return;
      final selfId = widget.seriesId;
      final items = page.items
          .where((s) =>
              s.id != selfId &&
              s.title.trim().isNotEmpty &&
              s.episodeCount > 0)
          .toList();
      setState(() => _sameName = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sameName = const []);
    }
  }

  /// 分区里的小封面（同名系列 / 季与合集共用）：44×60、sm 圆角。
  Widget _miniCover(String url, AppMetrics m) => SizedBox(
        width: 44,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(m.radiusSm)),
          child: CoverImage(url: url),
        ),
      );

  /// 「同名系列」分区：季与合集 / 同名系列 / 同名单剧三组。
  Widget _sameNameSection(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final items = _sameName;
    if (items == null) return const SizedBox.shrink();
    // 「季与合集」只由 album 提供（同一合集即同一作者）。这里既不再重复渲染
    // 该分组，也要剔除合集内已有条目，只留真正的其他作品。
    //
    // 搜索结果不返回 author 字段，无法按作者做严格过滤；合集成员关系是
    // 「同作者」在当前数据下唯一可信的依据。
    final albumIds = <String>{
      for (final s in _album?.seasons ?? const <Season>[]) s.seriesId,
    };
    final others = [
      for (final s in items)
        if (s.id != widget.seriesId && !albumIds.contains(s.id)) s,
    ];
    final series = [
      for (final s in others)
        if (_seasonMark.hasMatch(s.title) || _seasonMark.hasMatch(s.description))
          s,
    ];
    final singles = [
      for (final s in others)
        if (!_seasonMark.hasMatch(s.title) &&
            !_seasonMark.hasMatch(s.description))
          s,
    ];
    if (series.isEmpty && singles.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget group(String label, List<Widget> tiles) => tiles.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: m.s8,
            children: [
              Text(label, style: tokens.title),
              ...tiles,
            ],
          );

    List<Widget> tileList(List<SeriesSummary> list) => [
          for (final s in list)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _miniCover(s.coverUrl, m),
              title: Text(s.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              // `_loadSameName` 已剔除自身与 0 集数行，这里必然可播。
              subtitle: Text('共${s.episodeCount}集',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => openDetail(context, s.id, s.title,
                  coverHint: s.coverUrl, contentType: widget.contentType),
            ),
        ];

    return Padding(
      padding: EdgeInsets.fromLTRB(m.s16, m.s20, m.s16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: m.s8,
        children: [
          Text('同名系列', style: tokens.h3),
          group('同名系列', tileList(series)),
          group('同名单剧', tileList(singles)),
        ],
      ),
    );
  }

  /// 信息区层级（design.md §4.4）：剧名 `h1` → 元数据 `numbers`（等宽
  /// 数字，集数/热度/播放量）→ 演员 `label` → 标签 chip → 操作行。
  Widget _header(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final series = _series!;
    final scope = AppScope.read(context);
    final following = scope.follows.isFollowing(series.id);
    final heat = series.heat > 0 ? '${formatCount(series.heat)}热度' : '';
    final meta = [
      if (series.episodeCount > 0)
        series.status == 1 ? '全${series.episodeCount}集' : '更新至${series.episodeCount}集',
      heat,
      if (series.playCount > 0) '${formatCount(series.playCount)}播放',
    ].where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: EdgeInsets.fromLTRB(m.s16, m.s8, m.s16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: m.s12,
        children: [
          // Hero 目的端（E0）：无条件包裹（reduceMotion 时源端不包 Hero，
          // 两端不配对即不飞，Hero 静默退化为普通页面转场）。定宽的
          // SizedBox 留在 Hero 外侧——飞行副本取 Hero.child，若把
          // SizedBox 包进去，飞行插值框会把宽度钉死在 108。
          SizedBox(
            width: 108,
            child: Hero(
              tag: fxHeroSeriesCoverTag(series.id),
              child: ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(m.radiusMd)),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: CoverImage(url: series.coverUrl),
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: m.s6,
              children: [
                // E4「开演」仪式：剧名逐字 elasticOut 弹跳入场（数据到达
                // 即播一次；换剧复用组件树时文本变更重播；reduceMotion
                // 静态直出，Semantics 读完整标题）。
                FxTitleBounce(text: series.title, style: tokens.h1),
                if (meta.isNotEmpty)
                  Text(meta, style: tokens.numbers),
                if (series.actorLine.isNotEmpty)
                  Text(
                    '演员：${series.actorLine}',
                    style: tokens.label.copyWith(
                      color: tokens.colors.textSecondary,
                    ),
                  ),
                if (_tags(series).isNotEmpty)
                  Wrap(
                    spacing: m.s6,
                    runSpacing: m.s6,
                    children: [
                      for (final tag in _tags(series))
                        ActionChip(
                          label: Text(tag, style: tokens.caption),
                          visualDensity: VisualDensity.compact,
                          tooltip: '搜索「$tag」',
                          onPressed: () =>
                              showSearchScreen(context, query: tag),
                        ),
                    ],
                  ),
                Padding(
                  padding: EdgeInsets.only(top: m.s4),
                  child: Row(
                    spacing: m.s8,
                    children: [
                      // 果冻主操作（批次⑤ 补全「按钮用果冻」）：追剧 / 缓存。
                      JellyButton(
                        onTap: () async {
                          await scope.follows.toggle(
                            seriesId: series.id,
                            title: series.title,
                            coverUrl: series.coverUrl,
                            episodeCount: series.episodeCount,
                          );
                          if (context.mounted) setState(() {});
                        },
                        icon: following
                            ? AppIcons.favorite
                            : AppIcons.favoriteBorder,
                        label: following ? '已追' : '追剧',
                      ),
                      // 离线缓存：面板里选范围、看进度、可取消。
                      JellyButton(
                        onTap: () => _showDownloadSheet(context),
                        icon: AppIcons.download,
                        label: '缓存',
                      ),
                      if (scope.follows.get(series.id) != null)
                        _FollowStateMenu(entry: scope.follows.get(series.id)!),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeSection(BuildContext context) {
    final theme = Theme.of(context);
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final series = _series!;
    final desc = series.description;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.s16, m.s16, m.s16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: m.s8,
        children: [
          if (desc.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _descExpanded = !_descExpanded),
              child: Text(
                desc,
                maxLines: _descExpanded ? null : 2,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: tokens.body,
              ),
            ),
          if (series.rows.isNotEmpty)
            Wrap(
              spacing: m.s6,
              runSpacing: m.s6,
              children: [
                for (final r in series.rows)
                  if (r.kind == 3 || r.kind == 9 || r.kind == 40)
                    Container(
                      padding: EdgeInsets.fromLTRB(m.s8, m.s4, m.s8, m.s4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.all(
                          Radius.circular(m.radiusXs),
                        ),
                      ),
                      child: Text(r.text, style: tokens.caption),
                    ),
              ],
            ),
          // 选集标题与简介块之间要多一档呼吸（s8 队内间距 + s8 外边距 = 16）。
          Padding(
            padding: EdgeInsets.only(top: m.s8),
            child: Row(
              children: [
                Text('选集', style: tokens.h3),
                const Spacer(),
                if (_episodeHasMore)
                  TextButton(
                    onPressed: _loadMoreEpisodes,
                    child: const Text('加载更多'),
                  ),
              ],
            ),
          ),
          if (_episodes.isEmpty)
            const AppEmptyState(
              title: '该季还未上线',
              description: '先看看别的季吧',
            )
          else
            ListenableBuilder(
            listenable: AppScope.read(context).downloads,
            builder: (context, _) => GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 110,
              mainAxisSpacing: m.s8,
              crossAxisSpacing: m.s8,
              childAspectRatio: 1.6,
            ),
            itemCount: _episodes.length,
            itemBuilder: (context, i) {
              final ep = _episodes[i];
              return Builder(builder: (context) {
                final scope = AppScope.read(context);
                final h = scope.history.get(widget.seriesId);
                final watched = h != null &&
                    (h.finished || h.episode > ep.number);
                final downloaded = scope.downloads.store.has(ep.id);
                return InkWell(
                  onTap: ep.playable ? () => _play(ep, Duration.zero) : null,
                  borderRadius: BorderRadius.all(
                    Radius.circular(m.radiusSm),
                  ),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: watched
                          ? theme.colorScheme.surfaceContainerHigh
                          : theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.all(
                        Radius.circular(m.radiusSm),
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          ep.number.toString(),
                          // 集数是数字信息：等宽 tnum（design.md §4.4）；
                          // 看过的降为次要信息（等宽 + 次级文字色）。
                          style: watched
                              ? tokens.numbers.copyWith(
                                  color: tokens.colors.textTertiary,
                                )
                              : tokens.title.copyWith(
                                  color: theme
                                      .colorScheme.onPrimaryContainer,
                                ),
                        ),
                        if (downloaded)
                          Positioned(
                            right: m.s4,
                            top: m.s4,
                            child: Icon(AppIcons.downloaded,
                                size: 14,
                                color: theme.colorScheme.primary),
                          ),
                      ],
                    ),
                  ),
                );
              });
            },
          ),
        ),
        ],
      ),
    );
  }

  /// 离线缓存面板（共享组件，详情页与播放器选集抽屉共用）。
  void _showDownloadSheet(BuildContext context) {
    showDownloadSheet(
      context,
      series: _series!,
      episodes: _episodes,
    );
  }

  Widget _seasonsSection(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.s16, m.s20, m.s16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: m.s8,
        children: [
          Text('季与合集', style: tokens.h3),
          for (final (i, s) in _album!.seasons.indexed)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _miniCover(s.coverUrl, m),
              // 上游 season_index 缺失时为 0，直接打印会出现「0. 万妖图录传」。
              title: Text(
                  seasonTitleLabel(
                      index: s.index, title: s.title, position: i),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.seriesId == widget.seriesId
                  ? '当前季'
                  : s.episodeCount <= 0 ? '还未上线' : '共${s.episodeCount}集'),
              // 还没上线的季（服务端 episode_count=0）不可点，点了只会
              // 撞上设备配额或空数据（用户实测误报「匿名访问上限」）。
              onTap: s.seriesId == widget.seriesId || s.episodeCount <= 0
                  ? null
                  : () => openDetail(context, s.seriesId, s.title,
                      coverHint: s.coverUrl, contentType: widget.contentType),
            ),
        ],
      ),
    );
  }

  Widget _recommendSection(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final rec = _recommend!;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.s16, m.s20, m.s16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: m.s12,
        children: [
          Text(rec.cellTitle.isEmpty ? '相关推荐' : rec.cellTitle,
              style: tokens.h3),
          SizedBox(
            height: 200,
            // itemExtent 把卡宽钉在 96（SeriesCard 是 3:4 封面卡），
            // 右侧 12 由卡片自带的 Padding 让出，替代 separator 行。
            // HeroMode(false)：推荐卡不参与 Hero 飞行——本路由里已有同
            // tag 的头图 Hero，服务端推荐流混入自身/重复 id 时会触发
            // Flutter「multiple heroes share the same tag」硬断言。
            child: HeroMode(
              enabled: false,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemExtent: 108,
                itemCount: rec.items.length,
                itemBuilder: (context, i) {
                  final item = rec.items[i];
                  return Padding(
                    padding: EdgeInsets.only(right: m.s12),
                    child: SeriesCard(
                      item: item,
                      onTap: () => openDetail(context, item.id, item.title,
                          coverHint: item.coverUrl,
                          contentType: widget.contentType),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FollowStateMenu extends StatelessWidget {
  const _FollowStateMenu({required this.entry});

  final FollowEntry entry;

  @override
  Widget build(BuildContext context) {
    final AppMetrics m = context.app.metrics;
    return PopupMenuButton<FollowState>(
      initialValue: entry.state,
      onSelected: (state) async {
        // 状态只存在本地内存（_followState 简化）：写回 store。
        final scope = AppScope.read(context);
        await scope.follows.follow(
          seriesId: entry.seriesId,
          title: entry.title,
          coverUrl: entry.coverUrl,
          episodeCount: entry.episodeCount,
          state: state,
        );
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: FollowState.want, child: Text('想看')),
        PopupMenuItem(value: FollowState.watching, child: Text('在看')),
        PopupMenuItem(value: FollowState.watched, child: Text('已看')),
      ],
      child: Padding(
        padding: EdgeInsets.fromLTRB(m.s8, m.s6, m.s8, m.s6),
        child: Text('· ${switch (entry.state) {
          FollowState.want => '想看',
          FollowState.watching => '在看',
          FollowState.watched => '已看',
        }}',
            style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

/// 详情页入口（统一从这里打开，便于以后加埋点/转场）。
///
/// [coverHint]：入口卡片已有的封面 URL，仅为兼容既有调用保留——加载态已
/// 改为整页加载动画，不再渲染封面 / Hero 落点。
void openDetail(
  BuildContext context,
  String seriesId,
  String title, {
  String? coverHint,
  String contentType = '',
}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScreen(
      seriesId: seriesId,
      title: title,
      coverHint: coverHint,
      contentType: contentType,
    ),
  ));
}
