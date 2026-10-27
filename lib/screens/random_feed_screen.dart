import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/aqua_error.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 随机播放：全屏竖滑 feed（仿红果「随机看」）。
///
/// 候选池来自发现流多页 + 洗牌；每页自动播放该剧第 1 集（可在设置改为随机集），
/// 上滑换下一部剧，下滑回上一部。页内只保当前与相邻页的播放器。
class RandomFeedScreen extends StatefulWidget {
  const RandomFeedScreen({super.key, this.active = false});

  /// 主壳传下来的可见性：IndexedStack 会构建全部 tab，随机页只有第一次
  /// 可见时才拉候选池，避免启动即请求。
  final bool active;

  @override
  State<RandomFeedScreen> createState() => _RandomFeedScreenState();
}

class _RandomFeedScreenState extends State<RandomFeedScreen>
    with AutomaticKeepAliveClientMixin {
  final PageController _pageController = PageController();
  final List<SeriesSummary> _pool = [];
  final Map<int, _FeedEntry> _entries = {};
  bool _loadingPool = true;
  bool _loadingMore = false;
  Object? _error;
  String _discoverCursor = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.active) _fillPool();
  }

  @override
  void didUpdateWidget(covariant RandomFeedScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active && _pool.isEmpty && !_loadingPool) {
      _fillPool();
    }
  }

  @override
  void dispose() {
    for (final e in _entries.values) {
      e.dispose();
    }
    _pageController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _fillPool() async {
    setState(() {
      _loadingPool = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      final items = await api.randomCandidates(pages: 3);
      if (!mounted) return;
      setState(() {
        _pool
          ..clear()
          ..addAll(items);
        _loadingPool = false;
      });
      // 拉取第 1 页候选的详情与集数，同时准备首屏条目。
      await _hydrate(0);
      await _hydrate(1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loadingPool = false;
      });
    }
  }

  /// 条目懒加载：第 index 页进入视口前后准备数据与播放器。
  Future<void> _hydrate(int index) async {
    if (index < 0 || index >= _pool.length) return;
    if (_entries[index] != null) return;
    final summary = _pool[index];
    try {
      final scope = AppScope.read(context);
      final api = scope.api;
      final fromFirst = scope.settings.randomFromFirst;
      final series = await api.getSeries(summary.id);
      final eps = await api.listEpisodes(summary.id);
      if (eps.items.isEmpty) {
        _entries[index] = _FeedEntry(summary: summary, unavailable: true);
      } else {
        final startEp = fromFirst
            ? eps.items.first
            : eps.items[DateTime.now().millisecondsSinceEpoch % eps.items.length];
        final pb = await api.resolvePlayback(startEp.id);
        _entries[index] = _FeedEntry(
          summary: summary,
          series: series,
          episodes: eps.items,
          episode: startEp,
          playback: pb,
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      _entries[index] = _FeedEntry(
          summary: summary, unavailable: true, error: e);
      if (mounted) setState(() {});
    }
    // 池子快用完时提前补货。
    if (index > _pool.length - 4 && !_loadingMore) _loadMorePool();
  }

  Future<void> _loadMorePool() async {
    _loadingMore = true;
    try {
      final scope = AppScope.read(context);
      final page = await scope.api.discover(cursor: _discoverCursor);
      if (!mounted) return;
      setState(() {
        _pool.addAll(page.items);
        _discoverCursor = page.cursor;
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  void _onPageChanged(int index) {
    _hydrate(index + 1);
    // 离屏 2 页以外的播放器释放。
    for (final k in _entries.keys.toList()) {
      if ((k - index).abs() > 2) {
        _entries.remove(k)?.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loadingPool && _pool.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null && _pool.isEmpty) {
      return Scaffold(
        body: ErrorRetryView(error: _error!, onRetry: _fillPool),
      );
    }
    WakelockPlus.enable();
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        scrollDirection: Axis.vertical,
        controller: _pageController,
        onPageChanged: _onPageChanged,
        itemCount: _pool.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          if (entry == null) {
            _hydrate(index);
            return const Center(
                child: CircularProgressIndicator(color: Colors.white));
          }
          return _FeedPage(
            entry: entry,
            active: true,
            onOpenDetail: () => openDetail(
                context, entry.summary.id, entry.summary.title),
            onRetry: () {
              _entries.remove(index)?.dispose();
              _hydrate(index);
            },
          );
        },
      ),
    );
  }
}

class _FeedEntry {
  _FeedEntry({
    required this.summary,
    this.series,
    this.episodes = const [],
    this.episode,
    this.playback,
    this.unavailable = false,
    this.error,
  });

  final SeriesSummary summary;
  final Series? series;
  final List<Episode> episodes;
  final Episode? episode;
  final PlaybackResult? playback;
  final bool unavailable;
  final Object? error;

  Player? _player;
  VideoController? _controller;
  bool _playing = false;

  Player get player {
    _player ??= Player();
    return _player!;
  }

  VideoController get controller {
    _controller ??= VideoController(player);
    return _controller!;
  }

  Future<void> ensurePlaying(String quality) async {
    final pb = playback;
    if (pb == null || _playing) return;
    final usable = pb.playback.streams.where((s) => s.url.isNotEmpty).toList();
    if (usable.isEmpty) return;
    final key = pb.contentKey?.key ?? '';
    final p = player.platform;
    if (p is NativePlayer) {
      await p.setProperty(
        'demuxer-lavf-o',
        [
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
          if (key.isNotEmpty) 'decryption_key=$key',
        ].join(','),
      );
      await p.setProperty('hwdec', 'auto-copy');
    }
    // 简单选流：最高可用。
    usable.sort((a, b) => a.height.compareTo(b.height));
    await player.open(Media(usable.last.url), play: true);
    _playing = true;
  }

  Future<void> pause() async {
    if (_player != null) await _player!.pause();
  }

  void dispose() {
    _player?.dispose();
    _player = null;
    _controller = null;
  }
}

class _FeedPage extends StatelessWidget {
  const _FeedPage({
    required this.entry,
    required this.active,
    required this.onOpenDetail,
    required this.onRetry,
  });

  final _FeedEntry entry;
  final bool active;
  final VoidCallback onOpenDetail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (entry.unavailable || entry.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              entry.error is AquaException
                  ? (entry.error as AquaException).friendlyText
                  : '这一部暂时放不了，上滑换一部',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('重试', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }
    final series = entry.series;
    final ep = entry.episode;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 进入视口即播放（PageView 没有可见性回调，用 active 语义简化：当前页总是 active）。
        _ActiveVideo(entry: entry, active: active),
        // 底部信息与操作。
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                series?.title ?? entry.summary.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black45)],
                ),
              ),
              if ((series?.description ?? entry.summary.description)
                  .isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  series?.description ?? entry.summary.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black45)]),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: onOpenDetail,
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: Text(ep == null
                        ? '查看详情'
                        : '从第${ep.number}集开始看'),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: onOpenDetail,
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
              ),
            ],
          ),
        ),
        // 右侧提示。
        Positioned(
          top: MediaQuery.paddingOf(context).top + 12,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              '随机看 · 上下滑换剧',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

/// 播放条目视频；active 变化时播放/暂停。
class _ActiveVideo extends StatefulWidget {
  const _ActiveVideo({required this.entry, required this.active});

  final _FeedEntry entry;
  final bool active;

  @override
  State<_ActiveVideo> createState() => _ActiveVideoState();
}

class _ActiveVideoState extends State<_ActiveVideo> {
  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _ActiveVideo old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      if (widget.active) {
        _start();
      } else {
        widget.entry.pause();
      }
    }
  }

  Future<void> _start() async {
    final quality = AppScope.read(context).settings.defaultQuality;
    await widget.entry.ensurePlaying(quality);
    await widget.entry.player.play();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => widget.entry.player.playOrPause(),
      child: Video(controller: widget.entry.controller, controls: NoVideoControls),
    );
  }
}
