import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_log.dart';
import '../core/search/hongguo_web_search.dart';
import '../core/sources/source_adapter.dart';
import '../core/xifan/xifan_adapter.dart';
import '../core/xifan/xifan_api.dart';
import '../models/models.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'source_player_screen.dart';

/// 西饭剧集详情 + 选集。
///
/// 为什么不复用红果 `DetailScreen`：它写死 `AquaApi.getSeries/listEpisodes`，
/// 且历史/追剧/下载全按红果 id 建模；把西饭塞进去会连带改坏那条链路。
/// 这里只做详情与选集，播放交给现成的 `SourcePlayerScreen`（mpv 直链）。
class XifanDetailScreen extends StatefulWidget {
  const XifanDetailScreen({
    super.key,
    required this.source,
    required this.duanjuId,
    this.title = '',
    this.coverHint = '',
  });

  /// 从搜索结果的 `xifan:<source>:<duanjuId>` 还原。
  static XifanDetailScreen? fromSeriesId(
    String seriesId, {
    String title = '',
    String coverHint = '',
  }) {
    final XifanSearchItem? item = XifanSearchItem.fromSeriesId(seriesId);
    if (item == null) return null;
    return XifanDetailScreen(
      source: item.source,
      duanjuId: item.duanjuId,
      title: title,
      coverHint: coverHint,
    );
  }

  final String source;
  final String duanjuId;
  final String title;
  final String coverHint;

  @override
  State<XifanDetailScreen> createState() => _XifanDetailScreenState();
}

class _XifanDetailScreenState extends State<XifanDetailScreen> {
  final XifanApi _api = XifanApi();
  late final XifanAdapter _adapter = XifanAdapter(_api);

  XifanDrama? _drama;
  UnifiedSeries? _series;
  Object? _error;
  bool _loading = true;
  bool _expanded = false;
  bool _findingOnHongguo = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final XifanDrama drama = await _api.detail(widget.source, widget.duanjuId);
      if (!mounted) return;
      setState(() {
        _drama = drama;
        _series = XifanAdapter.toUnifiedDrama(drama);
        _loading = false;
      });
    } catch (e, st) {
      ErrorLog.instance.record(
        '西饭详情',
        '加载失败（${widget.duanjuId}）：$e',
        st,
      );
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _play(XifanEpisode episode) {
    final XifanDrama? drama = _drama;
    final UnifiedSeries? series = _series;
    if (drama == null || series == null) return;
    if (!episode.unlock || episode.playUrl.isEmpty) {
      _toast('该集在西饭需解锁，请在西饭官方客户端确认可看范围');
      return;
    }
    final PlayLine? line = series.defaultLine;
    if (line == null) {
      _toast('该剧暂无可播线路');
      return;
    }
    final int index =
        line.episodes.indexWhere((e) => e.index == episode.index);
    if (index < 0) {
      _toast('该集暂无可播地址');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourcePlayerScreen(
        source: SourceConfig(
          id: XifanAdapter.sourceKey,
          name: '西饭',
          apis: const <String>[XifanApi.base],
          headers: const <String, String>{'User-Agent': 'Mozilla/5.0'},
        ),
        series: series,
        line: line,
        startIndex: index,
        adapter: _adapter,
        resolvePlay: (UnifiedEpisode episode) async => ResolvedPlay(
          videoUrl: await _api.resolvePlayUrl(episode.url),
        ),
        // 西饭没有弹幕数据：不传 loadDanmaku，播放器不会显示弹幕入口。
      ),
    ));
  }

  /// 西饭很多剧在红果也有：一键跳到红果同名剧，能拿到官方弹幕与高清线路。
  Future<void> _findOnHongguo() async {
    final XifanDrama? drama = _drama;
    final String title = (drama?.title ?? widget.title).trim();
    if (title.isEmpty || _findingOnHongguo) return;
    setState(() => _findingOnHongguo = true);
    final HongguoWebSearch web = HongguoWebSearch();
    try {
      final AquaPage<SeriesSummary> page = await web.search(title);
      SeriesSummary? exact;
      for (final item in page.items) {
        if (item.title.trim() == title) {
          exact = item;
          break;
        }
      }
      // 只认同名：拿第一条会把人带到一部完全不相干的剧（红果没这部是常态）。
      if (exact == null) {
        _toast('红果没有找到同名剧「$title」');
        return;
      }
      if (!mounted) return;
      openDetail(context, exact.id, exact.title, coverHint: exact.coverUrl);
    } catch (e, st) {
      ErrorLog.instance.record('西饭详情', '红果同名剧查找失败：$e', st);
      _toast('红果备用接口暂不可用');
    } finally {
      web.close();
      if (mounted) setState(() => _findingOnHongguo = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final String appBarTitle =
        _drama?.title.isNotEmpty == true ? _drama!.title : widget.title;
    return Scaffold(
      appBar: AppBar(
        title: Text(appBarTitle.isEmpty ? '西饭短剧' : appBarTitle),
        actions: [
          if (_series != null)
            IconButton(
              tooltip: '在红果找同名剧',
              icon: _findingOnHongguo
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore_outlined),
              onPressed: _findingOnHongguo ? null : _findOnHongguo,
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return ErrorRetryView(error: _error!, onRetry: _load);
    }
    final XifanDrama? drama = _drama;
    if (drama == null) {
      return const Center(child: Text('没有拿到剧集信息'));
    }
    final List<XifanEpisode> episodes = drama.episodes;
    final double s16 = context.app.metrics.s16;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(context, drama)),
        SliverToBoxAdapter(
            child: _buildDescription(context, drama.description)),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(s16, s16, s16, 8),
            child: Row(
              children: [
                Text('选集',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('共 ${episodes.length} 集',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(s16, 0, s16, 32),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 86,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.7,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, i) => _episodeCell(context, episodes[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, XifanDrama drama) {
    final ThemeData theme = Theme.of(context);
    final double s16 = context.app.metrics.s16;
    final String cover =
        drama.coverUrl.isNotEmpty ? drama.coverUrl : widget.coverHint;
    return Padding(
      padding: EdgeInsets.fromLTRB(s16, s16, s16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(context.app.metrics.radiusXs),
            child: SizedBox(
              width: 116,
              height: 155,
              child: cover.isEmpty
                  ? const ColoredBox(color: Color(0x11000000))
                  : CoverImage(url: cover),
            ),
          ),
          SizedBox(width: s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  drama.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _tag(context, '西饭'),
                    if (drama.total > 0) _tag(context, '${drama.total} 集'),
                    for (final c in drama.categories.take(3))
                      _tag(context, c),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _findingOnHongguo ? null : _findOnHongguo,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('在红果找同名剧'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 简介：默认 3 行，可展开（西饭的 desc 常带换行，不展开会遮住选集）。
  Widget _buildDescription(BuildContext context, String description) {
    if (description.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(context.app.metrics.s16, 12,
          context.app.metrics.s16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _expanded ? '收起' : '展开',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(BuildContext context, String text) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(context.app.metrics.radiusXs),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }

  Widget _episodeCell(BuildContext context, XifanEpisode episode) {
    final ThemeData theme = Theme.of(context);
    final bool locked = !episode.unlock || episode.playUrl.isEmpty;
    return Material(
      key: ValueKey<String>('xifan-ep-${episode.episodeId}'),
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(context.app.metrics.radiusXs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _play(episode),
        child: Center(
          child: locked
              ? Icon(Icons.lock_outline,
                  size: 16, color: theme.colorScheme.outline)
              : Text(
                  '${episode.index}',
                  style: theme.textTheme.titleSmall,
                ),
        ),
      ),
    );
  }
}
