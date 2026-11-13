import 'dart:async';

import 'package:flutter/material.dart';

import '../core/aqua_error.dart';
import '../core/auto_retry.dart';
import '../core/discover_channels.dart';
import '../core/error_log.dart';
import '../core/history_cover_refresh.dart';
import '../core/history_rail_collapse.dart';
import '../core/series_meta.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import '../widgets/back_to_top.dart';
import '../widgets/common.dart';
import '../widgets/glass/glass_overlay.dart';
import '../widgets/jelly/jelly_press.dart';
import '../widgets/jelly/jelly_surface.dart';
import '../widgets/reading_rail.dart';
import '../widgets/tv_scope.dart';
import '../widgets/ui/app_card.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/ui/app_section.dart';
import 'book_aggregation_screen.dart';
import 'book_category_screen.dart';
import 'book_detail_screen.dart';
import 'community_screen.dart';
import 'detail_screen.dart';
import 'filter_screen.dart';
import 'media_hub_screen.dart';
import 'releases_screen.dart';
import 'search_screen.dart';
import 'venera_manga_screen.dart';

/// 发现页：内容类型条 + 类型内频道条 + 多列网格（分页加载）。
///
/// 两级导航：
/// - 一级 [kContentTypes] 常驻在滚动区之外，加载/错误态下也能换类型；
/// - 二级只在当前类型的频道数 > 1 时出现（目前只有短剧有 4 个）。
/// 频道的数据源（书城频道 / 短剧榜单）由 `lib/core/discover_channels.dart`
/// 的 [DiscoverChannel.source] 决定。
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with AutomaticKeepAliveClientMixin {
  final _items = <SeriesSummary>[];
  final _badges = <String, String>{};

  /// 已展示的榜单名次数（「广告」角标不计）。翻页时作为下一页的起始号，
  /// 让推荐行之后的卡片名次连续。
  int _rankPlaces = 0;

  /// [channelKey] → (榜单内容 id, 榜单 id)。榜单目录由服务端下发，选定一次就
  /// 固定；翻页必须带同一组值，否则游标无法续接。
  final _rankTargets = <String, ({String content, String board})>{};

  /// 类型名 → 该类型上次选中的频道，切走再切回不重置。
  final _lastChannelByType = <String, DiscoverChannel>{};

  ContentType _type = kDefaultContentType;
  DiscoverChannel _channel = kDefaultChannel;

  String _cursor = '';
  bool _hasMore = false;

  /// 已展示过的条目 id：服务端游标边界重复时不再追加。
  final Set<String> _seenIds = <String>{};
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  /// 首载自愈已用掉的自动重试次数（手动重试/换频道会清零）。
  ///
  /// 首启的第一次请求落在网络/DNS 冷启动窗口里容易失败（用户实测「第一次
  /// 打开进入失败，过几秒自动刷新才出来」）；重试期间保持骨架屏，两次快速
  /// 重试都失败才亮错误页。
  int _retry = 0;

  /// 每次加载自增，只有最新一次的结果能落地：连续切类型/频道时先发起的响应
  /// 不会覆盖后发起的那次。
  int _seq = 0;

  /// 历史条（继续观看 / 最近在读）的折叠状态。
  ///
  /// 不持久化：每次进入页面都是展开的。用户手动展开后，直到滚回顶部之前
  /// 不再自动折叠，否则「刚点开就被下一次滚动收起」。
  final ScrollController _scroll = ScrollController();
  bool _historyCollapsed = false;
  bool _manualExpandUntilTop = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 「继续观看」直接渲染历史里的封面快照，而封面 URL 带签名（约 60 天
    // 过期）；进页后批量回源刷新一次，否则过期后这里是裂图。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _refreshContinueCovers(),
    );
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final offset = _scroll.offset;
    // 回到顶部才自动展开，避免上滑后立刻又弹回来。
    if (shouldUnfoldHistoryRail(offset: offset, collapsed: _historyCollapsed)) {
      setState(() {
        _historyCollapsed = false;
        _manualExpandUntilTop = false;
      });
      return;
    }
    if (shouldFoldHistoryRail(
      offset: offset,
      collapsed: _historyCollapsed,
      manualExpand: _manualExpandUntilTop,
    )) {
      setState(() => _historyCollapsed = true);
    }
  }

  /// 历史条标题行的 ↑ / ↓ 按钮。
  void _toggleHistory() {
    setState(() {
      _historyCollapsed = !_historyCollapsed;
      _manualExpandUntilTop = !_historyCollapsed;
    });
  }

  Future<void> _reload({bool allowFallback = true}) async =>
      _reloadWithSelfHeal(allowFallback: allowFallback);

  /// 实际加载；自动重试的续跑传 [keepSelfHealBudget] = true，不重置额度。
  Future<void> _reloadWithSelfHeal({
    bool allowFallback = true,
    bool keepSelfHealBudget = false,
  }) async {
    if (!keepSelfHealBudget) _retry = 0;
    final seq = ++_seq;
    final type = _type;
    final channel = _channel;
    setState(() {
      _loading = true;
      _error = null;
      // 换类型时上一个类型的触底请求还在飞，别让它挡住新类型的加载更多。
      _loadingMore = false;
    });
    try {
      final page = await _fetchPage(type, channel, '');
      if (!mounted || seq != _seq) return;
      setState(() {
        _seenIds.clear();
        _items
          ..clear()
          ..addAll(_dedupe(page.items));
        _badges
          ..clear()
          ..addAll(page.badges);
        _rankPlaces = page.places;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // 网格改成 sliver 后不再由 SeriesGrid 内部预取，这里补上首屏预热。
      _warmCovers();
      // 列表接口不带热度（发现流）或连标签都不带（榜单）：后台补详情元信息。
      // 小说/书籍行不是剧集 ID，详情批量接口只会白跑，按内容类型跳过。
      if (type.kind == ContentKind.video) {
        _enrichMeta(List.of(_items), seq);
      }
      // 榜单降级提示只在这次结果真正落地时弹，避免切走后弹出过期提示。
      final notice = page.notice;
      if (notice != null) _snack(notice);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (channel.source == DiscoverSource.ranking) {
        // 榜单目录可能已被服务端下线：丢掉缓存，下次进入重新解析榜名，
        // 否则本会话会一直拿着失效的 board id 失败。
        _rankTargets.remove(channelKey(type, channel));
      }
      if (allowFallback &&
          !(type == kDefaultContentType && channel == kDefaultChannel)) {
        // 非默认组合拉不动时退回短剧/推荐，不让用户停在错误页。
        // 同时忘掉这个类型上次选的频道，避免下次切回来又自动选中失败的频道。
        _lastChannelByType.remove(type.name);
        _lastChannelByType[kDefaultContentType.name] = kDefaultChannel;
        setState(() {
          _type = kDefaultContentType;
          _channel = kDefaultChannel;
        });
        _snack('${_friendly(e)}，已切回推荐');
        await _reload(allowFallback: false);
        return;
      }
      // 首载自愈：瞬时网络类错误自动快速重试（400ms / 900ms），重试期间
      // 保持骨架屏（_loading 仍为 true），两次都失败才亮错误页。
      final delay = selfHealDelay(e, _retry);
      if (delay != null) {
        _retry++;
        await Future<void>.delayed(delay);
        if (!mounted || seq != _seq) return;
        return _reloadWithSelfHeal(
          allowFallback: allowFallback,
          keepSelfHealBudget: true,
        );
      }
      ErrorLog.instance.record('发现', '加载失败：$e', StackTrace.current);
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _error != null) return;
    final seq = _seq;
    final type = _type;
    final channel = _channel;
    _loadingMore = true;
    try {
      final page = await _fetchPage(
        type,
        channel,
        _cursor,
        badgeStart: _rankPlaces,
      );
      if (!mounted || seq != _seq) return;
      final fresh = _dedupe(page.items);
      setState(() {
        if (fresh.isEmpty && page.items.isNotEmpty) {
          // 整页都是已展示过的条目：游标没前进，判定到底，别再空转。
          _hasMore = false;
        } else {
          _items.addAll(fresh);
          _hasMore = page.hasMore;
        }
        _badges.addAll(page.badges);
        _rankPlaces += page.places;
        _cursor = page.cursor;
      });
      if (type.kind == ContentKind.video) _enrichMeta(fresh, seq);
    } catch (_) {
      // 触底加载失败静默，下次触底再试。榜单目录可能已失效，丢掉缓存让
      // 下拉刷新/切回时重新解析榜名，不要整会话沿用旧 board id。
      if (channel.source == DiscoverSource.ranking) {
        _rankTargets.remove(channelKey(type, channel));
      }
    } finally {
      // 只有这一代请求才有资格解锁：被切类型顶掉的旧请求不能把新请求的
      // 翻页锁清掉，否则会重复追加同一页。
      if (seq == _seq) _loadingMore = false;
    }
  }

  /// 列表接口的热度/标签缺口（发现流缺热度、榜单两者都缺）后台补详情；
  /// 原地替换已展示条目，[seq] 变了（切类型/频道）后丢弃。
  void _enrichMeta(List<SeriesSummary> items, int seq) {
    if (items.isEmpty) return;
    final api = AppScope.read(context).api;
    unawaited(
      SeriesMetaEnricher.instance.enrich(items, api.getSeriesBatch).then((
        enriched,
      ) {
        if (!mounted || seq != _seq || enriched.isEmpty) return;
        final byId = {for (final item in enriched) item.id: item};
        setState(() {
          for (var i = 0; i < _items.length; i++) {
            final next = byId[_items[i].id];
            if (next != null) _items[i] = next;
          }
        });
      }, onError: (Object _) {}),
    );
  }

  /// 回源刷新「继续观看」的封面（最多 10 条）。
  ///
  /// 不回写 UI：`HistoryStore.refreshCovers` 会 `notifyListeners`，
  /// [_ContinueRail] 的 `ListenableBuilder` 自己会重建。24 小时节流与
  /// 静默失败都在 [refreshHistoryCovers] 里。
  Future<void> _refreshContinueCovers() async {
    if (!mounted) return;
    final scope = AppScope.read(context);
    final ids = scope.history.entries
        .where((e) => !e.finished)
        .take(10)
        .map((e) => e.seriesId)
        .toList();
    await refreshHistoryCovers(scope.api, scope.history, ids);
  }

  /// 预热首屏封面（前 12 张）。
  ///
  /// 网格改成 sliver 之后不再走 `SeriesGrid` 内置的 `CoverPrefetch`，但预取
  /// 本身仍然有价值：命中时 `AquaImageCache.load` 直接返回内存/磁盘字节。
  void _warmCovers() {
    if (_items.isEmpty) return;
    final api = AppScope.read(context).api;
    final limit = TvScope.isTvOf(context) ? 8 : 12;
    for (final item in _items.take(limit)) {
      if (item.coverUrl.isEmpty) continue;
      unawaited(
        AquaImageCache.instance
            .load(item.coverUrl, api)
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  /// 过滤掉已经展示过的条目（保持首次出现顺序）。
  List<SeriesSummary> _dedupe(List<SeriesSummary> items) {
    final out = <SeriesSummary>[];
    for (final item in items) {
      if (item.id.isEmpty) {
        out.add(item);
        continue;
      }
      if (_seenIds.add(item.id)) out.add(item);
    }
    return out;
  }

  /// 按频道来源取一页，两个数据源都归一化成 [_ChannelPage]。
  ///
  /// 榜单名次由 Go 侧跨页全局化后直接下发（`Position += len(cur.Seen)`），
  /// 这里只做展示转换，不能再叠加任何偏移。
  /// [badgeStart] 是上一页已展示的名次数：榜单名次在本地按顺序累计，
  /// 「平台推荐」行只给「广告」角标、不占号。
  Future<_ChannelPage> _fetchPage(
    ContentType type,
    DiscoverChannel channel,
    String cursor, {
    int badgeStart = 0,
  }) async {
    final api = AppScope.read(context).api;
    if (channel.source == DiscoverSource.feed) {
      final page = await api.discover(channel: channel.value, cursor: cursor);
      return _ChannelPage(
        items: page.items,
        cursor: page.cursor,
        hasMore: page.hasMore,
      );
    }

    final key = channelKey(type, channel);
    final target = _rankTargets[key];
    var ranking = await api.shortRank(
      content: target?.content ?? kShortRankContentAll,
      board: target?.board ?? '',
      cursor: cursor,
    );
    String? notice;
    // 只有首页（无游标）才解析榜单目录：翻页必须沿用游标里的榜单，否则会把
    // 第一页再追加一次。
    if (target == null && cursor.isEmpty) {
      // 第一次进入这个频道：用服务端下发的目录选榜。
      final content = primaryRankContent(ranking.contents);
      final boards = content?.boards ?? const <RankBoard>[];
      final matched = matchBoard(boards, channel.boardKeywords);
      final board = matched ?? defaultBoard(boards);
      final contentId = content?.id ?? kShortRankContentAll;
      if (board == null) {
        // 目录缺失时直接展示服务端默认榜，翻页仍可续接游标。
        final badges = rankBadges(ranking.items, start: badgeStart);
        return _ChannelPage(
          items: rankItemsToSummaries(ranking.items),
          badges: badges.badges,
          places: badges.places,
          cursor: ranking.cursor,
          hasMore: ranking.hasMore,
        );
      }
      _rankTargets[key] = (content: contentId, board: board.id);
      if (matched == null && channel.boardKeywords.isNotEmpty) {
        notice = '当前榜单暂无「${channel.name}」榜，已展示默认榜';
      }
      if (ranking.board != board.id) {
        // 首屏给的是默认榜，换成匹配到的榜重拉第一页。
        ranking = await api.shortRank(content: contentId, board: board.id);
      }
    }
    final badges = rankBadges(ranking.items, start: badgeStart);
    return _ChannelPage(
      items: rankItemsToSummaries(ranking.items),
      badges: badges.badges,
      places: badges.places,
      notice: notice,
      cursor: ranking.cursor,
      hasMore: ranking.hasMore,
    );
  }

  void _selectType(ContentType type) {
    if (_type == type) return;
    _lastChannelByType[_type.name] = _channel;
    setState(() {
      _type = type;
      _channel = _lastChannelByType[type.name] ?? type.channels.first;
      // 换 tag 回到展开态：新的 tag 有自己的历史条。
      _historyCollapsed = false;
      _manualExpandUntilTop = false;
    });
    _reload();
  }

  void _selectChannel(DiscoverChannel channel) {
    if (_channel == channel) return;
    _lastChannelByType[_type.name] = channel;
    setState(() => _channel = channel);
    _reload();
  }

  void _open(SeriesSummary item) {
    switch (_type.kind) {
      case ContentKind.video:
        openDetail(context, item.id, item.title);
      case ContentKind.community:
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const CommunityScreen()));
      case ContentKind.book:
      case ContentKind.manga:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BookDetailScreen(
              bookId: item.id,
              title: item.title,
              coverUrl: item.coverUrl,
              manga: _type.kind == ContentKind.manga,
            ),
          ),
        );
    }
  }

  String _friendly(Object error) =>
      error is AquaException ? error.friendlyText : '出了点小问题';

  /// 错误面板「立即重置」：换一台匿名设备后重拉当前频道。
  Future<void> _resetDeviceAndReload() async {
    final api = AppScope.read(context).api;
    final ok = await resetAnonymousDevice(context, api.resetDevice);
    if (!ok || !mounted) return;
    unawaited(_reload());
  }

  void _snack(String text) {
    // 玻璃提示条（design.md §11.3 overlay 档）：外壳与守卫都在
    // `showGlassToast` 里（mounted / ScaffoldMessenger.maybeOf）。
    if (!mounted) return;
    if (context.mounted) {
      showGlassToast(context, text);
    }
  }

  /// 统一 IA：每个 tag 两张入口卡——「XX聚合」+「按分类找XX」。
  /// 影视三 tab 共用影视聚合（TVBox 源内容覆盖短剧/漫剧/电影）。
  List<Widget> _entriesFor(ContentType type) {
    Widget card(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback onTap,
    ) => _EntryCard(icon: icon, title: title, subtitle: subtitle, onTap: onTap);
    switch (type.name) {
      case '短剧':
      case '漫剧':
        final genre = type.name == '短剧' ? 'short_play' : 'comic_series';
        return [
          card(
            AppIcons.liveTv,
            '影视聚合',
            'TVBox / 采集站源聚合搜索与观看',
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MediaHubScreen())),
          ),
          card(
            AppIcons.category,
            '按分类找${type.name}',
            '体裁、年代、主题、排序筛选',
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FilterScreen(initialGenre: genre),
              ),
            ),
          ),
        ];
      case '电影':
        // 服务端 shortFilter 只接受 short_play / comic_series / ai_series，
        // 没有电影体裁：传 'movie' 会命中 SDK 的 unknown genre 校验并报错。
        // 电影的真实来源是影视聚合（TVBox 源），所以这里不给分类入口。
        return [
          card(
            AppIcons.liveTv,
            '影视聚合',
            'TVBox / 采集站源聚合搜索与观看；电影分类筛选暂未开放',
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MediaHubScreen())),
          ),
        ];
      case '小说':
        return [
          card(
            AppIcons.book,
            '小说聚合',
            'legado 书源聚合搜索与阅读（导入书源后可用）',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BookAggregationScreen()),
            ),
          ),
          card(
            AppIcons.category,
            '按分类找书',
            '玄幻、言情、都市、悬疑……',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BookCategoryScreen()),
            ),
          ),
        ];
      case '漫画':
        return [
          card(
            AppIcons.book,
            '漫画聚合',
            '多漫画源浏览与阅读（拷贝/包子/漫画柜…可切换）',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VeneraMangaScreen()),
            ),
          ),
          card(
            AppIcons.category,
            '按分类找漫画',
            '源内分类：恋爱、古风、悬疑、生活……',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VeneraMangaScreen()),
            ),
          ),
        ];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          IconButton(
            icon: const Icon(AppIcons.newReleases),
            tooltip: '上新',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ReleasesScreen())),
          ),
          IconButton(
            tooltip: '社区',
            icon: const Icon(AppIcons.community),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const CommunityScreen())),
          ),
          IconButton(
            icon: const Icon(AppIcons.search),
            onPressed: () => showSearchScreen(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 固定不滚动：骨架屏/错误页时类型条仍然可用。
          _ContentTypeBar(selected: _type, onSelect: _selectType),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: _reload,
              // 设备被限/被拒时给「立即重置」，不必绕道「我的 → 设置」。
              onResetDevice: _error != null && deviceRecoverable(_error!)
                  ? _resetDeviceAndReload
                  : null,
              empty: _items.isEmpty,
              // 能力未接入的类型，空态直接说清楚原因。
              emptyText: _type.notice.isNotEmpty
                  ? _type.notice
                  : '${_type.name}暂无内容',
              child: RefreshIndicator(
                onRefresh: _reload,
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // 统一 IA：每个 tag 两张入口卡——「XX聚合」+「按分类找XX」。
                    for (final entry in _entriesFor(_type))
                      SliverToBoxAdapter(child: entry),
                    // 继续观看只在影视类 tab；「最近在读」按小说/漫画分域
                    // （各 tag 的历史记录互不混排）。
                    if (_type.kind == ContentKind.video)
                      SliverToBoxAdapter(
                        child: _ContinueRail(
                          collapsed: _historyCollapsed,
                          onToggleCollapsed: _toggleHistory,
                        ),
                      ),
                    if (_type.kind == ContentKind.book)
                      SliverToBoxAdapter(
                        child: ReadingRail(
                          manga: false,
                          collapsed: _historyCollapsed,
                          onToggleCollapsed: _toggleHistory,
                        ),
                      ),
                    if (_type.kind == ContentKind.manga)
                      SliverToBoxAdapter(
                        child: ReadingRail(
                          manga: true,
                          collapsed: _historyCollapsed,
                          onToggleCollapsed: _toggleHistory,
                        ),
                      ),
                    if (_type.channels.length > 1)
                      SliverToBoxAdapter(
                        child: _ChannelBar(
                          type: _type,
                          selected: _channel,
                          onSelect: _selectChannel,
                        ),
                      ),
                    if (_type.notice.isNotEmpty)
                      SliverToBoxAdapter(child: _NoticeBar(text: _type.notice)),
                    // 必须用 sliver 网格，不能用 SliverFillRemaining + SeriesGrid：
                    // 后者会形成第二个滚动视口，滚网格时外层 offset 不变，
                    // 历史条的自动收起就只在页面上半部分生效。
                    SliverSeriesGrid(
                      items: _items,
                      hasMore: _hasMore,
                      onLoadMore: _loadMore,
                      badgeOf: (item) => _badges[item.id],
                      onTap: _open,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      // 四个内容 tab 共用同一个滚动控制器，所以一个按钮就够。
      floatingActionButton: BackToTopFab(controller: _scroll),
    );
  }
}

/// 统一入口卡：发现页每个 tag 的「XX聚合」/「按分类找XX」共用这一张卡。
///
/// 视觉收敛到 `AppCard.row`（design.md §5.2）：四态交互、字阶、描边都由
/// 组件层统一提供，这里只剩「前导图标 + 文案 + 果冻按压」三件事。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, 0),
      child: JellyPress(
        strength: 0.03,
        child: AppCard.row(
          leading: Icon(icon, color: tokens.colors.brand),
          title: title,
          subtitle: subtitle,
          trailing: Icon(
            AppIcons.chevronRight,
            color: tokens.colors.textTertiary,
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _ContentTypeBar extends StatelessWidget {
  const _ContentTypeBar({required this.selected, required this.onSelect});

  final ContentType selected;
  final ValueChanged<ContentType> onSelect;

  /// 电视上隐藏小说（`ContentKind.book`）——书架/阅读器/听书在电视上没有意义。
  List<ContentType> _visibleTypes(BuildContext context) {
    if (!TvScope.isTvOf(context)) return kContentTypes;
    return kContentTypes
        .where((type) => type.kind != ContentKind.book)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    // 底色交给 Material：InkWell 的水波纹画在 Material 上，用不透明 Container
    // 当底会把波纹盖掉。
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: tokens.colors.hairline),
          ),
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(m.s8, 0, m.s8, 0),
          children: [
            // 电视不提供小说/漫画阅读（用户明确不需要），类型条直接不显示。
            for (final type in _visibleTypes(context))
              _TypeTab(
                type: type,
                selected: type == selected,
                onTap: () => onSelect(type),
              ),
          ],
        ),
      ),
    );
  }
}

/// 类型 Tab：选中态是一块「实心果冻」凝胶（`JellySurface`，snap 手感），
/// 未选中保持普通文字 + 水波纹。
///
/// - 凝胶块挂载（切到该 tab）时 `popOnMount` 先压后弹，替代旧版 3dp 指示线
///   （AC2.2 的「字号+字重」区分保留，指示器形态按父任务交接 T1.3 换成凝胶）。
/// - 选中态的按压反馈由 `JellySurface` 自己的手势驱动，不再走 InkWell；
///   未选中态仍走 InkWell，保证 48 高整块可点。
/// - 五个类型名都是两字，凝胶块取固定 64×32。
class _TypeTab extends StatelessWidget {
  const _TypeTab({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final ContentType type;
  final bool selected;
  final VoidCallback onTap;

  /// 凝胶块静止尺寸：两字 15px ≈ 30 宽，左右各留 17。
  static const Size _gelSize = Size(64, 32);

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final Widget content = selected
        ? JellySurface(
            size: _gelSize,
            elevation: 6,
            popOnMount: true,
            onTap: onTap,
            child: Text(
              type.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.title.copyWith(color: tokens.colors.onBrand),
            ),
          )
        : Text(
            type.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.body.copyWith(color: tokens.colors.textSecondary),
          );
    return Semantics(
      selected: selected,
      button: true,
      label: type.name,
      onTap: onTap, // excludeSemantics 会丢掉子树的点击动作，这里显式补上。
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(m.s12, 0, m.s12, 0),
        child: selected
            // 凝胶块占满 48 高的命中区（JellySurface 内部自己居中）。
            ? Center(child: content)
            : InkWell(
                onTap: onTap,
                child: Center(child: content),
              ),
      ),
    );
  }
}

/// 二级：当前类型下的频道。只有 `channels.length > 1` 时才挂载。
class _ChannelBar extends StatelessWidget {
  const _ChannelBar({
    required this.type,
    required this.selected,
    required this.onSelect,
  });

  final ContentType type;
  final DiscoverChannel selected;
  final ValueChanged<DiscoverChannel> onSelect;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(tokens.metrics.s12, 0, tokens.metrics.s12, 0),
        children: [
          for (final channel in type.channels)
            Padding(
              padding: EdgeInsets.only(right: tokens.metrics.s8),
              child: ChoiceChip(
                label: Text(channel.name),
                selected: channel == selected,
                onSelected: (_) => onSelect(channel),
              ),
            ),
        ],
      ),
    );
  }
}

/// 能力尚未接入的类型在列表顶部的说明条。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Container(
      margin: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, 0),
      padding: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, m.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.all(Radius.circular(m.radiusSm)),
      ),
      child: Row(
        spacing: m.s8,
        children: [
          Icon(
            AppIcons.info,
            size: m.s16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          Expanded(
            child: Text(
              text,
              style: tokens.caption.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个频道当前页的归一化结果：书城频道没有名次，榜单频道有名次。
class _ChannelPage {
  const _ChannelPage({
    required this.items,
    this.badges = const {},
    this.places = 0,
    this.notice,
    this.cursor = '',
    this.hasMore = false,
  });

  final List<SeriesSummary> items;
  final Map<String, String> badges;

  /// 本页占用的榜单名次数（「广告」角标不计），下一页从它继续编号。
  final int places;

  /// 这次结果的轻提示（如榜单降级），由调用方在结果落地时弹出。
  final String? notice;
  final String cursor;
  final bool hasMore;
}

/// 「继续观看」：最近没看完的剧横排，点了直接续播到上次那一集那一秒。
/// 「继续观看」：最近没看完的剧横排，点了直接续播到上次那一集那一秒。
/// 看完的（finished）不出现；看完入口在「我的 → 观看历史」。
class _ContinueRail extends StatelessWidget {
  const _ContinueRail({this.collapsed = false, this.onToggleCollapsed});

  /// true = 折叠成一条约 40dp 的标题栏（不渲染卡片）。
  final bool collapsed;

  /// 收起/展开回调；null 表示不显示按钮。
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.history,
      builder: (context, _) {
        // position==0 也算：用户显式跳集的「意图记录」（history-jump-episode）
        // 落盘时就在 0 秒，过滤掉会让这部剧从「继续观看」里整个消失。
        final entries = scope.history.entries
            .where((e) => !e.finished)
            .take(10)
            .toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        final AppTokens tokens = context.app;
        final AppMetrics m = tokens.metrics;
        // brandGlowSoft：全项目唯一允许的头图光晕（design.md §4.6 白名单）。
        // 铺在「继续观看」横幅背后，光源取顶部中央——剧场顶灯打在海报行上。
        final RadialGradient glow = tokens.metrics.brandGlowSoft.gradientAt(
          tokens.colors.brand,
          const Alignment(0, -1.6),
        );
        return Padding(
          padding: EdgeInsets.only(top: m.s8, bottom: m.s4),
          child: AnimatedSize(
            duration: AppMetrics.reduceMotionOf(context, m.enter),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: glow),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: m.s8,
                children: [
                  AppSectionHeader(
                    title: '继续观看',
                    subtitle: collapsed ? '共${entries.length}部' : null,
                    collapsed: collapsed,
                    onToggle: onToggleCollapsed,
                    padding: EdgeInsets.fromLTRB(m.s16, 0, m.s4, 0),
                  ),
                  if (!collapsed)
                    SizedBox(
                      // AppCard.wide：16:9 缩略图(72) + 上下内边距(8×2) = 88，
                      // 留 8 给描边呼吸。
                      height: 96,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.fromLTRB(m.s12, 0, m.s12, 0),
                        itemExtent: 300,
                        children: [
                          for (final e in entries) _ContinueCard(entry: e),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 「继续观看」单张卡：收敛到 `AppCard.wide`（design.md §5.2——
/// 继续观看/历史/推荐用 16:9 缩略图 + 右侧文字块），按压果冻沿用
/// `_EntryCard` 的同档手感（strength 0.03）。
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    return Padding(
      padding: EdgeInsets.only(right: tokens.metrics.s12),
      child: JellyPress(
        strength: 0.03,
        child: AppCard.wide(
          image: CoverImage(
            url: entry.coverUrl,
            // 只记 seriesId / 标题：完整 URL 带签名，不入日志。
            onFetchError: () => ErrorLog.instance.record(
              '封面',
              '继续观看加载失败 seriesId=${entry.seriesId} '
                  'title=${entry.title}',
            ),
          ),
          title: entry.title,
          subtitle: entry.episodes > 0
              ? '第${entry.episode}/${entry.episodes}集'
              : '第${entry.episode}集',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DetailScreen(
                seriesId: entry.seriesId,
                title: entry.title,
                autoplay: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
