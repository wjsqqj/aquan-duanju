import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/download_service.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import 'player_screen.dart';

/// 详情页：封面头部 + 操作行 + 剧集网格 + 相关推荐。
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.seriesId,
    this.title = '',
    this.autoplay = false,
  });

  final String seriesId;
  final String title;

  /// AI / 命令行要求「直接开播」时置真：详情加载完立刻进播放器，
  /// 有观看历史就从上次那一集那一秒续播。
  final bool autoplay;

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

  @override
  void initState() {
    super.initState();
    _reload();
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
      if (widget.autoplay && !_didAutoplay && _episodes.isNotEmpty) {
        _didAutoplay = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final (ep, start) = _resumeTarget();
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
  (Episode, Duration) _resumeTarget() {
    final scope = AppScope.read(context);
    final h = scope.history.get(widget.seriesId);
    if (h != null && !h.finished && h.position > 5) {
      Episode target;
      try {
        target = _episodes.firstWhere((e) => e.number == h.episode);
      } catch (_) {
        target = _episodes.first;
      }
      return (target, Duration(seconds: h.position.floor()));
    }
    return (_episodes.first, Duration.zero);
  }

  void _play(Episode ep, Duration start) {
    final series = _series;
    if (series == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        series: series,
        episodes: _episodes,
        startIndex: _episodes.indexOf(ep),
        startAt: start,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final series = _series;
    return Scaffold(
      body: _loading
          ? const SkeletonGrid(columns: 1)
          : _error != null
              ? ErrorRetryView(error: _error!, onRetry: _reload)
              : SafeArea(
                  child: CustomScrollView(
                    slivers: [
                      SliverAppBar(
                        pinned: true,
                        title: Text(series?.title ?? widget.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        leading: BackButton(onPressed: () => Navigator.pop(context)),
                      ),
                      SliverToBoxAdapter(child: _header(context)),
                      SliverToBoxAdapter(child: _episodeSection(context)),
                      if (_album != null && _album!.seasons.length > 1)
                        SliverToBoxAdapter(child: _seasonsSection(context)),
                      if (_recommend != null && _recommend!.items.isNotEmpty)
                        SliverToBoxAdapter(child: _recommendSection(context)),
                      const SliverToBoxAdapter(
                          child: SizedBox(height: 32)),
                    ],
                  ),
                ),
      floatingActionButton: (!_loading && _error == null && _episodes.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: () {
                final (ep, start) = _resumeTarget();
                _play(ep, start);
              },
              icon: const Icon(Icons.play_arrow),
              label: Builder(builder: (context) {
                final scope = AppScope.read(context);
                final h = scope.history.get(widget.seriesId);
                final ep = (h != null && h.position > 5 && !h.finished)
                    ? '继续播放 第${h.episode}集'
                    : '立即播放';
                return Text(ep);
              }),
            )
          : null,
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 108,
              height: 152,
              child: CoverImage(url: series.coverUrl),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(series.title,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(meta,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ],
                if (series.actorLine.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () {
                      // 演员行没有单独 id，跳人物页需要 user_id；没有则不跳。
                    },
                    child: Text('演员：${series.actorLine}',
                        style: theme.textTheme.bodySmall),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await scope.follows.toggle(
                          seriesId: series.id,
                          title: series.title,
                          coverUrl: series.coverUrl,
                          episodeCount: series.episodeCount,
                        );
                        if (context.mounted) setState(() {});
                      },
                      icon: Icon(following
                          ? Icons.favorite
                          : Icons.favorite_border),
                      label: Text(following ? '已追' : '追剧'),
                    ),
                    const SizedBox(width: 8),
                    // 离线缓存：面板里选范围、看进度、可取消。
                    FilledButton.tonalIcon(
                      onPressed: () => _showDownloadSheet(context),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('缓存'),
                    ),
                    const SizedBox(width: 8),
                    if (scope.follows.get(series.id) != null)
                      _FollowStateMenu(entry: scope.follows.get(series.id)!),
                  ],
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
    final series = _series!;
    final desc = series.description;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (desc.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _descExpanded = !_descExpanded),
              child: Text(
                desc,
                maxLines: _descExpanded ? null : 2,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (series.rows.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in series.rows)
                  if (r.kind == 3 || r.kind == 9 || r.kind == 40)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(r.text, style: theme.textTheme.bodySmall),
                    ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Text('选集',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_episodeHasMore)
                TextButton(
                  onPressed: _loadMoreEpisodes,
                  child: const Text('加载更多'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: AppScope.read(context).downloads,
            builder: (context, _) => GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 110,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
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
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: watched
                          ? theme.colorScheme.surfaceContainerHigh
                          : theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          ep.number.toString(),
                          style: TextStyle(
                            color: watched
                                ? theme.colorScheme.outline
                                : theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (downloaded)
                          Positioned(
                            right: 4,
                            top: 4,
                            child: Icon(Icons.download_done,
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

  /// 离线缓存面板：范围、实时进度、取消与删除。
  void _showDownloadSheet(BuildContext context) {
    final scope = AppScope.read(context);
    final service = scope.downloads;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: Listenable.merge([service, service.store]),
        builder: (context, _) {
          final series = _series!;
          final episodes = _episodes.where((e) => e.playable).toList();
          final downloaded =
              episodes.where((e) => service.store.has(e.id)).length;
          final active = service.activeCount(series.id);
          final tasks = service.tasks.values
              .where((t) => t.episode.seriesId == series.id)
              .toList();
          final running =
              tasks.where((t) => t.state == DownloadState.running).toList();
          final failed = tasks
              .where((t) => t.state == DownloadState.failed)
              .length;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('离线缓存 · ${series.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    '已缓存 $downloaded / ${episodes.length} 集'
                    '${active > 0 ? ' · 下载中 $active 集' : ''}'
                    '${failed > 0 ? ' · 失败 $failed 集' : ''}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                  if (running.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final t in running.take(1))
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('第${t.episode.number}集'
                              ' ${t.episode.title.isEmpty ? '' : t.episode.title}'),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                              value: t.progress > 0 ? t.progress : null),
                        ],
                      ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: active > 0
                              ? null
                              : () {
                                  final added =
                                      service.enqueue(series, episodes);
                                  Navigator.pop(sheetContext);
                                  ScaffoldMessenger.maybeOf(context)
                                      ?.showSnackBar(SnackBar(
                                      content: Text(added > 0
                                          ? '已加入 $added 集下载队列'
                                          : '没有需要下载的集')));
                                },
                          icon: const Icon(Icons.download_outlined),
                          label: Text(
                              downloaded >= episodes.length ? '重新补缺' : '缓存全剧'),
                        ),
                      ),
                      if (active > 0) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => service.cancelSeries(series.id),
                          child: const Text('取消下载'),
                        ),
                      ],
                      if (downloaded > 0 && active == 0) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () async {
                            await service.deleteSeries(series.id);
                          },
                          child: const Text('删除缓存'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _seasonsSection(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('季与合集',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final s in _album!.seasons)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 44,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CoverImage(url: s.coverUrl),
                ),
              ),
              title: Text('${s.index}. ${s.title}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.seriesId == widget.seriesId
                  ? '当前季'
                  : '共${s.episodeCount}集'),
              onTap: s.seriesId == widget.seriesId
                  ? null
                  : () => openDetail(context, s.seriesId, s.title),
            ),
        ],
      ),
    );
  }

  Widget _recommendSection(BuildContext context) {
    final theme = Theme.of(context);
    final rec = _recommend!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(rec.cellTitle.isEmpty ? '相关推荐' : rec.cellTitle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: rec.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final item = rec.items[i];
                return SizedBox(
                  width: 96,
                  child: SeriesCard(
                    item: item,
                    onTap: () => openDetail(context, item.id, item.title),
                  ),
                );
              },
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
void openDetail(BuildContext context, String seriesId, String title) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScreen(seriesId: seriesId, title: title),
  ));
}
