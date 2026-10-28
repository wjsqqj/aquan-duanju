import 'package:flutter/material.dart';

import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'releases_screen.dart';
import 'search_screen.dart';

/// 发现页：分类 chips + 双列网格（分页加载）。
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with AutomaticKeepAliveClientMixin {
  final _items = <SeriesSummary>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  String? _channel;
  List<Map<String, String>> _channels = const [];

  bool _fetching = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (_fetching) return;
    _fetching = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scope = AppScope.read(context);
      final page = await scope.api.discover(channel: _channel ?? '');
      if (_channels.isEmpty) {
        // 频道列表固定几个书城入口；服务端没有列出频道名的接口，按红果书城常量。
        _channels = const [
          {'name': '推荐', 'value': ''},
          {'name': '新剧', 'value': '新剧'},
          {'name': '热剧', 'value': '热剧'},
          {'name': '爆款好剧', 'value': '爆款好剧'},
          {'name': '漫剧', 'value': '漫剧'},
        ];
      }
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } finally {
      _fetching = false;
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _error != null) return;
    _loadingMore = true;
    try {
      final scope = AppScope.read(context);
      final page = await scope.api.discover(
          channel: _channel ?? '', cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // 触底加载失败静默，下次触底再试。
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          IconButton(
            icon: const Icon(Icons.event),
            tooltip: '上新',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReleasesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => showSearchScreen(context),
          ),
        ],
      ),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _reload,
        empty: _items.isEmpty,
        child: RefreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              const SliverToBoxAdapter(child: _ContinueRail()),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final c in _channels)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(c['name']!),
                            selected: _channel == c['value'],
                            onSelected: (_) {
                              setState(() => _channel = c['value']);
                              _reload();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SliverFillRemaining(
                hasScrollBody: true,
                child: SeriesGrid(
                  items: _items,
                  hasMore: _hasMore,
                  onLoadMore: _loadMore,
                  onTap: (item) => openDetail(context, item.id, item.title),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「继续观看」：最近没看完的剧横排，点了直接续播到上次那一集那一秒。
/// 看完的（finished）不出现；看完入口在「我的 → 观看历史」。
class _ContinueRail extends StatelessWidget {
  const _ContinueRail();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.history,
      builder: (context, _) {
        final entries = scope.history.entries
            .where((e) => !e.finished && e.position > 5)
            .take(10)
            .toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('继续观看',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 172,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final e in entries) _ContinueCard(entry: e),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DetailScreen(
          seriesId: entry.seriesId,
          title: entry.title,
          autoplay: true,
        ),
      )),
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 104,
                      height: 140,
                      child: CoverImage(url: entry.coverUrl),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        entry.episodes > 0
                            ? '第${entry.episode}/${entry.episodes}集'
                            : '第${entry.episode}集',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
