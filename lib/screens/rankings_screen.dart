import 'package:flutter/material.dart';

import '../core/rankings_session_cache.dart';
import '../models/models.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import '../widgets/glass/glass_app_bar.dart';
import '../widgets/jelly/jelly_press.dart';
import '../widgets/jelly/jelly_chip.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/ui/app_badge.dart';
import '../widgets/ui/app_card.dart';
import '../widgets/ui/app_pull_refresh.dart';
import '../widgets/back_to_top.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'filter_screen.dart';
import 'person_screen.dart';
import '../widgets/loading.dart';

/// 榜单页：shortRank 的内容 tab + 榜 tab + 榜单列表（分页）。
///
/// 会话缓存（1.12.16）：重进先用 [RankingsSessionCache] 即时渲染（无等待感），
/// 后台静默刷新覆盖；下拉刷新 / 切榜仍正常请求。失败不写缓存。
class RankingsScreen extends StatefulWidget {
  const RankingsScreen({super.key});

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen>
    with AutomaticKeepAliveClientMixin {
  List<RankContent> _contents = const [];
  String _contentId = '';
  String _boardId = '';
  final _items = <RankItem>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  /// 当前列表来自会话缓存（刷新成功后清掉；刷新失败保留，静默不报错）。
  bool _showingCache = false;

  /// 请求代际：后台静默刷新与切榜 / 下拉刷新并发时，旧响应不得覆盖新状态。
  int _seq = 0;

  /// 榜单列表滚动控制器：给「回到顶部」用。
  final ScrollController _listScroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 先用会话缓存即时渲染（同步、命中才有），再联网刷新：无等待感、
    // 不闪骨架。水合期间首帧已在路上，刷新走 post-frame（setState 不能
    // 在 initState 同步调用）。
    final hydrated = _hydrateFromSessionCache();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload(silent: hydrated);
    });
  }

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
  }

  /// 服务端默认 tab/榜的解析口径（首拉与缓存水合共用，同源防漂移）。
  static (RankContent, RankBoard) _resolveDefault(List<RankContent> contents) {
    final content = contents.firstWhere(
      (c) => c.selected,
      orElse: () => contents.isNotEmpty ? contents.first : const RankContent(),
    );
    final board = content.boards.firstWhere(
      (b) => b.selected,
      orElse: () => content.boards.isNotEmpty
          ? content.boards.first
          : const RankBoard(),
    );
    return (content, board);
  }

  /// 用会话缓存填充首屏（无缓存 / 空页静默跳过）。返回是否命中。
  bool _hydrateFromSessionCache() {
    final contents = RankingsSessionCache.instance.contents;
    if (contents == null || contents.isEmpty) return false;
    final (content, board) = _resolveDefault(contents);
    final page = RankingsSessionCache.instance.pageOf(content.id, board.id);
    if (page == null || page.items.isEmpty) return false;
    _contents = contents;
    _contentId = content.id;
    _boardId = board.id;
    _items
      ..clear()
      ..addAll(page.items);
    _cursor = page.cursor;
    _hasMore = page.hasMore;
    _loading = false;
    _showingCache = true;
    return true;
  }

  /// 首拉 / 错误页重试 / 缓存命中的后台刷新。
  ///
  /// [silent] = true 用于「缓存已经在屏上」的后台刷新：不闪骨架、不清列表，
  /// 失败保留缓存内容（下拉可再试）。
  Future<void> _reload({bool silent = false}) async {
    final seq = ++_seq;
    setState(() {
      _loading = !silent || _items.isEmpty;
      _error = null;
      _loadingMore = false; // 上一个榜挂起的「加载更多」不堵新请求
    });
    try {
      final api = AppScope.read(context).api;
      final first = await api.shortRank();
      if (!mounted || seq != _seq) return;
      final contents = first.contents;
      final (content, board) = _resolveDefault(contents);
      setState(() {
        _contents = contents;
        _contentId = content.id;
        _boardId = board.id;
        _items
          ..clear()
          ..addAll(first.items);
        _cursor = first.cursor;
        _hasMore = first.hasMore;
        _loading = false;
        _showingCache = false;
      });
      RankingsSessionCache.instance.rememberFirst(
        contents: contents,
        contentId: content.id,
        boardId: board.id,
        items: first.items,
        cursor: first.cursor,
        hasMore: first.hasMore,
      );
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (_showingCache) {
        // 缓存已在屏上：静默失败，保留旧内容（下拉可再试）。
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _switch(String content, String board) async {
    final seq = ++_seq;
    setState(() {
      _contentId = content;
      _boardId = board;
      _items.clear();
      _loading = true;
      _error = null;
      _loadingMore = false;
      _showingCache = false;
    });
    try {
      final page = await AppScope.read(context)
          .api
          .shortRank(content: content, board: board);
      if (!mounted || seq != _seq) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // 切榜成功也进会话缓存（tab+榜维度）；失败不写（catch 不落）。
      RankingsSessionCache.instance.rememberPage(
        contentId: content,
        boardId: board,
        items: page.items,
        cursor: page.cursor,
        hasMore: page.hasMore,
      );
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 下拉刷新：当前 tab+榜强制走网络（绕过缓存），成功写缓存；失败保留
  /// 现有内容静默结束（下拉可再试）。
  Future<void> _refresh() async {
    final seq = ++_seq;
    _loadingMore = false;
    try {
      final page = await AppScope.read(context)
          .api
          .shortRank(content: _contentId, board: _boardId);
      if (!mounted || seq != _seq) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _error = null;
        _showingCache = false;
      });
      RankingsSessionCache.instance.rememberPage(
        contentId: _contentId,
        boardId: _boardId,
        items: page.items,
        cursor: page.cursor,
        hasMore: page.hasMore,
      );
    } catch (_) {
      // 刷新失败保留现有内容，静默结束。
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    _loadingMore = true;
    final seq = _seq;
    try {
      final page = await AppScope.read(context)
          .api
          .shortRank(content: _contentId, board: _boardId, cursor: _cursor);
      if (!mounted || seq != _seq) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      if (seq == _seq) _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final content = _contents.where((c) => c.id == _contentId).firstOrNull;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: '榜单',
        actions: <Widget>[
          IconButton(
            icon: const Icon(AppIcons.tune),
            tooltip: '筛选',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FilterScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        // 顶栏占位要含系统状态栏（安卓）。
        padding: EdgeInsets.only(
          top: GlassAppBar.bodyTopInset(context) + context.app.metrics.s8,
        ),
        child: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _reload,
        empty: _items.isEmpty,
        child: Column(
          children: [
            // 内容 tab（全部/真人剧/漫剧……）
            if (_contents.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final c in _contents)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: JellyChip(
                          label: c.name,
                          selected: c.id == _contentId,
                          onSelected: (_) =>
                              _switch(c.id, c.boards.firstOrNull?.id ?? ''),
                        ),
                      ),
                  ],
                ),
              ),
            // 榜 tab（推荐榜/热播榜……）
            if (content != null && content.boards.length > 1)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final b in content.boards)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TextButton(
                          onPressed: () => _switch(_contentId, b.id),
                          child: Text(
                            b.name,
                            style: TextStyle(
                              color: b.id == _boardId
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                              fontWeight: b.id == _boardId
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              // 下拉刷新（box 降级路线）：当前 tab+榜强制请求第一页。
              child: AppPullRefresh(
                onRefresh: _refresh,
                child: ListView.builder(
                  controller: _listScroll,
                  // 内容不足一屏也能下拉（RefreshIndicator 需要 overscroll）。
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: _items.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= _items.length) {
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _loadMore());
                      return const Padding(
                        padding: EdgeInsets.fromLTRB(AppSpacing.s16, AppSpacing.s16, AppSpacing.s16, AppSpacing.s16),
                        child: Center(
                            child: AppLoading.inline()),
                      );
                    }
                    final item = _items[i];
                    return _RankTile(item: item);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      ),
      floatingActionButton: BackToTopFab(controller: _listScroll),
    );
  }
}

class _RankTile extends StatelessWidget {
  const _RankTile({required this.item});

  final RankItem item;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final change = item.change;
    final changeText = change == null
        ? null
        : switch (change.kind) {
            0 => '新',
            1 => '↑${change.places}',
            2 => '↓${change.places}',
            _ => '-',
          };
    // 名次列是「前导内容」而非图标：保留自定义列，交给 AppCard.row 的 leading。
    final Widget leading = SizedBox(
      width: 56,
      child: Column(
        spacing: m.s2,
        children: [
          Text(
            '${item.position > 0 ? item.position : item.rank}',
            style: tokens.h3.copyWith(
              color: item.position <= 3
                  ? tokens.colors.brand
                  : tokens.colors.textTertiary,
            ),
          ),
          if (changeText != null)
            Text(changeText,
                style: tokens.caption.copyWith(
                  color: change?.kind == 1
                      ? tokens.colors.danger
                      : change?.kind == 2
                          ? tokens.colors.success
                          : tokens.colors.textTertiary,
                )),
        ],
      ),
    );
    // Q 弹按压（与发现页入口卡同档 0.03）：按下挤压、松手回弹。
    return JellyPress(
      strength: 0.03,
      child: AppCard.row(
      leading: leading,
      title: item.title,
      titleTrailing: item.promoted
          ? const AppBadge(text: '推广', tone: AppBadgeTone.neutral)
          : null,
      subtitle: [
        if (item.score.isNotEmpty) item.score,
        if (item.episodeCount > 0) '共${item.episodeCount}集',
        if (item.actor.isNotEmpty) item.actor,
      ].join(' · '),
      trailing: SizedBox(
        width: 48,
        height: 68,
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(m.radiusXs)),
          child: CoverImage(
              url: item.seriesId.isEmpty && item.avatarUrl.isNotEmpty
                  ? item.avatarUrl
                  : item.coverUrl),
        ),
      ),
      // 演员行的 seriesId 为空、user_id 指向人物主页；剧集行照常进详情。
      onTap: item.seriesId.isNotEmpty
          ? () => openDetail(context, item.seriesId, item.title,
              coverHint: item.coverUrl)
          : item.userId.isNotEmpty
              ? () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PersonScreen(
                      userId: item.userId,
                      name: item.actor,
                    ),
                  ))
              : null,
    ),
    );
  }
}
