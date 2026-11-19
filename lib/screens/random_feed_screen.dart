import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../theme/app_metrics.dart';
import '../theme/player_overlay_theme.dart';
import '../core/app_route_observer.dart';
import '../core/aqua_api.dart';
import '../core/error_log.dart';
import '../core/last_route.dart';
import '../core/aqua_error.dart';
import '../core/player/mpv_list_encoding.dart';
import '../models/models.dart';
import '../widgets/ui/app_gap.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/ui/app_toast.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import '../widgets/loading.dart';

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
    with AutomaticKeepAliveClientMixin, RouteAware {
  final PageController _pageController = PageController();
  final List<SeriesSummary> _pool = [];
  final Map<int, _FeedEntry> _entries = {};
  final Set<int> _hydrating = {};
  // 初始必须是 false：首屏不是「随机」时不会触发加载，若这里为 true，
  // 切到随机页后 didUpdateWidget 会因 !_loadingPool 不成立而永远不拉数据。
  bool _loadingPool = false;
  bool _loadingMore = false;
  Object? _error;
  String _discoverCursor = '';

  /// 是否被压在首页之上的页面路由盖住（搜索页 / 详情页 / 播放页）。
  /// 盖住时必须静音，返回首页且 tab 仍是随机时再恢复。
  bool _covered = false;

  /// PageView 当前停住的页码：只有这一页可以出声，相邻页只预取不出声。
  int _current = 0;

  /// 连续自动跳过的部数：源站取不到流时自动换下一部，最多连跳 3 次，
  /// 避免整池不可播时在 feed 里空转。
  int _autoSkips = 0;
  bool _autoSkipScheduled = false;
  static const int _maxAutoSkips = 3;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      WakelockPlus.enable();
      _fillPool();
    }
  }

  @override
  void didUpdateWidget(covariant RandomFeedScreen old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      WakelockPlus.enable();
      _resumeCurrent();
      if (_pool.isEmpty && !_loadingPool) _fillPool();
    } else {
      // 切到发现 / 榜单 / 我的时，随机页仍在 IndexedStack 里存活，
      // 必须显式暂停，否则声音会一直播。
      _pauseAll();
      WakelockPlus.disable();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      appRouteObserver.subscribe(this, route);
    }
  }

  /// 被搜索页/详情页/播放页等页面路由盖住：立即静音，别和上层播放器叠音。
  @override
  void didPushNext() {
    if (!mounted || _covered) return;
    setState(() => _covered = true);
    _pauseAll();
  }

  /// 回到首页：只有当前 tab 仍是随机时才恢复，不能把别的 tab 的随机页唤醒。
  @override
  void didPopNext() {
    if (!mounted || !_covered) return;
    setState(() => _covered = false);
    if (widget.active) _resumeCurrent();
  }

  void _pauseAll() {
    for (final entry in _entries.values) {
      entry.pause();
    }
  }

  Future<void> _resumeCurrent() async {
    if (!widget.active || _covered) return;
    await _entries[_current]?.play();
  }

  Future<void> _openDetailPaused(int index, _FeedEntry entry) async {
    _pauseAll();
    await Navigator.of(context).push(MaterialPageRoute(
      // 冷启动会话恢复（R1）：观察者靠 name + arguments 记「上次停留页」。
      settings: RouteSettings(
        name: kRouteNameDetail,
        arguments: LastRoute.detail(seriesId: entry.summary.id),
      ),
      builder: (_) => DetailScreen(
        seriesId: entry.summary.id,
        title: entry.summary.title,
        coverHint: entry.summary.coverUrl,
      ),
    ));
    if (mounted && widget.active) {
      await _entries[index]?.play();
    }
  }

  @override
  void dispose() {
    for (final e in _entries.values) {
      e.dispose();
    }
    _pageController.dispose();
    WakelockPlus.disable();
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  Future<void> _fillPool() async {
    setState(() {
      _loadingPool = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      // 防止某个发现页请求卡死时整个随机页一直转圈。
      final items = await api
          .randomCandidates(pages: 3)
          .timeout(const Duration(seconds: 20));
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
    if (!_hydrating.add(index)) return;
    final summary = _pool[index];
    try {
      final scope = AppScope.read(context);
      final api = scope.api;
      final fromFirst = scope.settings.randomFromFirst;
      final series =
          await api.getSeries(summary.id).timeout(const Duration(seconds: 15));
      final eps = await api
          .listEpisodes(summary.id)
          .timeout(const Duration(seconds: 15));
      if (eps.items.isEmpty) {
        _entries[index] = _FeedEntry(summary: summary, unavailable: true);
      } else {
        final startEp = fromFirst
            ? eps.items.first
            : eps.items[DateTime.now().millisecondsSinceEpoch % eps.items.length];
        // 取流路线必须与播放器页一致：只走旧 App 取流接口会整池空响应。
        final pb = await _resolveFeedPlayback(
          api,
          summary.id,
          startEp.id,
          scope.settings.defaultQuality,
        ).timeout(const Duration(seconds: 20));
        _entries[index] = _FeedEntry(
          summary: summary,
          series: series,
          episodes: eps.items,
          episode: startEp,
          playback: pb,
        );
      }
      if (mounted) setState(() {});
      // 当前页准备成功（切页时它还没 hydrate 的情况）：连跳计数同样清零。
      final ready = _entries[index];
      if (index == _current &&
          ready != null &&
          !ready.unavailable &&
          ready.error == null) {
        _autoSkips = 0;
      }
      _scheduleAutoSkip();
    } catch (e, st) {
      _entries[index] = _FeedEntry(
          summary: summary, unavailable: true, error: e);
      // 随机池里的失败必须留痕：源站空响应 / 下架都只能靠这条定位是哪一部。
      ErrorLog.instance.record(
        '随机播放',
        '第${index + 1}部《${summary.title}》(series=${summary.id}) 准备失败：$e',
        st,
      );
      if (mounted) setState(() {});
      _scheduleAutoSkip();
    } finally {
      _hydrating.remove(index);
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

  /// 「换一部」：跳到下一个候选；池子见底时先补货。
  void _skipToNext() {
    final next = _pageController.hasClients
        ? (_pageController.page?.round() ?? 0) + 1
        : 1;
    if (next < _pool.length) {
      _hydrate(next);
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      _loadMorePool();
    }
  }

  void _onPageChanged(int index) {
    // 只有停住的这一页可以出声；其它页立即静音，离屏 2 页以外的播放器释放。
    if (index != _current) setState(() => _current = index);
    for (final k in _entries.keys.toList()) {
      if (k != index) _entries[k]?.pause();
      // 离屏 2 页以外的播放器释放。
      if ((k - index).abs() > 2) {
        _entries.remove(k)?.dispose();
      }
    }
    final entry = _entries[index];
    // 轮到一部能播的：连跳计数清零（「连续 3 部」按实际播放序列算）。
    if (entry != null && !entry.unavailable && entry.error == null) {
      _autoSkips = 0;
    }
    _hydrate(index + 1);
    _scheduleAutoSkip();
  }

  /// 源站侧不可恢复的失败：取流空响应 / 内容下架 / 合集不可用。
  /// 这几类点「重试」也多半不恢复，不该拿错误卡把整个 feed 堵死。
  bool _isUnplayable(Object? error) {
    if (error is! AquaException) return false;
    switch (error.code) {
      case AquaCode.playbackUnavailable:
      case AquaCode.contentUnavailable:
      case AquaCode.albumUnavailable:
        return true;
      default:
        return false;
    }
  }

  /// 当前页不可播就自动换下一部；连续 3 部都不可播时停下，把选择权还给用户。
  void _scheduleAutoSkip() {
    if (_autoSkipScheduled || !mounted || !widget.active || _covered) return;
    if (_autoSkips >= _maxAutoSkips) return;
    final entry = _entries[_current];
    if (entry == null) return;
    if (!entry.unavailable && !_isUnplayable(entry.error)) return;
    _autoSkipScheduled = true;
    final title = entry.summary.title;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoSkipScheduled = false;
      // 这一帧里可能已经切了页 / 换了条目：重新判定，不要凭旧快照跳。
      if (!mounted || !widget.active || _covered) return;
      if (!_pageController.hasClients) return;
      final now = _entries[_current];
      if (now == null) return;
      if (!now.unavailable && !_isUnplayable(now.error)) return;
      if (_autoSkips >= _maxAutoSkips) return;
      // 后面没有候选页时别假装跳过了：留在错误卡，等用户上滑或补货。
      if (_current + 1 >= _pool.length) return;
      _autoSkips++;
      ErrorLog.instance
          .record('随机播放', '自动跳过《$title》（连续 $_autoSkips/$_maxAutoSkips 部不可播）');
      AppToast.show(context, '《$title》暂时取不到播放地址，已自动换下一部');
      _skipToNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loadingPool && _pool.isEmpty) {
      return const Scaffold(body: SkeletonView(layout: SkeletonLayout.grid));
    }
    if (_error != null && _pool.isEmpty) {
      return Scaffold(
        body: ErrorRetryView(error: _error!, onRetry: _fillPool),
      );
    }
    return Scaffold(
      backgroundColor: PlayerOverlayTokens.videoBlack,
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
                child: AppLoading(color: PlayerOverlayTokens.textPrimary));
          }
          return _FeedPage(
            entry: entry,
            // 页面被搜索/详情/播放页压住时也算「不可见」，必须停声。
            active: widget.active && !_covered,
            // 只有 PageView 停住的那一页可以出声。
            current: index == _current,
            onOpenDetail: () => _openDetailPaused(index, entry),
            onRetry: () {
              _entries.remove(index)?.dispose();
              _hydrate(index);
            },
            onSkip: _skipToNext,
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

  /// 用户/页面「想让它出声」的意愿位。异步链路（选流 → setProperty →
  /// open）随时可能被滑走、切 tab、被路由盖住打断，只有意愿位仍在时才
  /// 能在 open 完成后起播，否则就是「回魂」（后台残留音源）。
  bool _wantPlay = false;
  bool _disposed = false;

  /// 是否已经打开过流：返回已看过的页面时用来避免闪转圈。
  bool get isOpened => _playing;

  /// 当前是否仍被希望出声（异步链路末尾据此判断能不能续播）。
  bool get isWanted => _wantPlay;

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
    if (pb == null) throw StateError('没有播放数据');
    // 已释放的条目不能再取 `player` getter（会新建一个没人收的 Player）。
    if (_disposed) return;
    // 全程持有本地实例：`dispose()` 后 getter 会重建播放器，是隐蔽的残留音源。
    final p = player;
    // 已经打开过流：只按意愿位起停。再 open 一次会从头播，且会盖掉用户的暂停。
    if (_playing) {
      if (_wantPlay) await p.play();
      return;
    }
    final usable = pb.playback.streams.where((s) => s.url.isNotEmpty).toList();
    if (usable.isEmpty) throw StateError('没有可用播放流');
    final key = pb.contentKey?.key ?? '';
    final engine = p.platform;
    if (engine is NativePlayer) {
      await engine.setProperty(
        'demuxer-lavf-o',
        [
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          lavfProtocolWhitelist(protocols: kMpvLavfNetworkProtocols),
          if (key.isNotEmpty) 'decryption_key=$key',
        ].join(','),
      );
      await engine.setProperty('network-timeout', '20');
      await engine.setProperty('cache', 'yes');
      await engine.setProperty('demuxer-max-bytes', '64MiB');
      await engine.setProperty('hwdec', 'auto-copy');
      // DASH 双轨（官网 play-info 通道）：音轨是独立流，必须在 open 之前挂上。
      // audio-files 是路径列表：URL 要经 mpvListEntry 转义（Android 的 ':'
      // 分隔符会把 'https://...' 切碎，11-20）；audioUrl 为空时用 change-list
      // clr 清残留——setProperty 传空串会被 parse_str_list 先放入一条空条目
      // （「Cannot open file ''」，11-17 事故）。
      final audioUrl = pb.playback.audioUrl;
      if (audioUrl.isNotEmpty) {
        await engine.setProperty('audio-files', mpvListEntry(audioUrl));
      } else {
        await engine.command(mpvClearPathListCommand('audio-files'));
      }
    }
    // 按默认清晰度选流：best / 具体标签走最高可用，worst 取最低。
    usable.sort((a, b) {
      final ra = a.height > 0
          ? a.height
          : (int.tryParse(
                  RegExp(r'^(\d+)').firstMatch(a.definition)?.group(1) ?? '') ??
              0);
      final rb = b.height > 0
          ? b.height
          : (int.tryParse(
                  RegExp(r'^(\d+)').firstMatch(b.definition)?.group(1) ?? '') ??
              0);
      if (ra != rb) return ra.compareTo(rb);
      return a.bitrate.compareTo(b.bitrate);
    });
    VideoStream pick;
    if (quality == 'worst') {
      pick = usable.first;
    } else if (quality == '' || quality == 'best') {
      pick = usable.last;
    } else {
      pick = usable.lastWhere(
        (s) =>
            s.definition == quality ||
            s.quality == quality ||
            s.codec == quality,
        orElse: () => usable.last,
      );
    }
    // 选流期间条目可能已经被换掉/释放：不再 open，避免复活一个没人持有的音源。
    if (_disposed) return;
    // 先 `play: false`：起播由意愿位决定，open 期间被滑走/被盖住就保持静音。
    await p.open(Media(pick.url), play: false);
    // open 期间被释放的条目已经由 dispose() 收过播放器（media_kit 重复 dispose
    // 会抛 AssertionError），这里只保证不再起播。
    if (_disposed) return;
    _playing = true;
    if (_wantPlay) await p.play();
  }

  Future<void> play() async {
    _wantPlay = true;
    final p = _player;
    if (p != null) await p.play();
  }

  Future<void> pause() async {
    _wantPlay = false;
    final p = _player;
    if (p != null) await p.pause();
  }

  void dispose() {
    _disposed = true;
    _wantPlay = false;
    _playing = false;
    _player?.dispose();
    _player = null;
    _controller = null;
  }
}

class _FeedPage extends StatelessWidget {
  const _FeedPage({
    required this.entry,
    required this.active,
    required this.current,
    required this.onOpenDetail,
    required this.onRetry,
    required this.onSkip,
  });

  final _FeedEntry entry;

  /// tab 级可见性（被路由盖住时也为 false）。
  final bool active;

  /// 是否 PageView 停住的当前页：只有它为 true 的页可以出声。
  final bool current;
  final VoidCallback onOpenDetail;
  final VoidCallback onRetry;
  final VoidCallback onSkip;

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
              style: PlayerOverlayTokens.styleSecondary,
              textAlign: TextAlign.center,
            ),
            AppGap.v(AppGapSize.s12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('重试',
                      style: PlayerOverlayTokens.stylePrimary),
                ),
                AppGap.h(AppGapSize.s12),
                OutlinedButton(
                  onPressed: onSkip,
                  child: const Text('换一部',
                      style: PlayerOverlayTokens.stylePrimary),
                ),
              ],
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
        // 进入视口即预取；只有 current 的那一页真正出声。
        _ActiveVideo(
          entry: entry,
          active: active,
          current: current,
          onSkip: onSkip,
        ),
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
                  color: PlayerOverlayTokens.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(blurRadius: 8, color: PlayerOverlayTokens.hudFill)],
                ),
              ),
              if ((series?.description ?? entry.summary.description)
                  .isNotEmpty) ...[
                AppGap.v(AppGapSize.s6),
                Text(
                  series?.description ?? entry.summary.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: PlayerOverlayTokens.textSecondary,
                      fontSize: 13,
                      shadows: [Shadow(blurRadius: 8, color: PlayerOverlayTokens.hudFill)]),
                ),
              ],
              AppGap.v(AppGapSize.s12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: onOpenDetail,
                    icon: const Icon(AppIcons.play, size: 20),
                    label: Text(ep == null
                        ? '查看详情'
                        : '从第${ep.number}集开始看'),
                  ),
                  AppGap.h(AppGapSize.s8),
                  IconButton.filledTonal(
                    onPressed: onOpenDetail,
                    icon: const Icon(AppIcons.info),
                  ),
                  AppGap.h(AppGapSize.s8),
                  // 一键追剧：图标随追剧状态实时变化。
                  ListenableBuilder(
                    listenable: AppScope.read(context).follows,
                    builder: (context, _) {
                      final scope = AppScope.read(context);
                      final following =
                          series != null && scope.follows.isFollowing(series.id);
                      return IconButton.filledTonal(
                        onPressed: series == null
                            ? null
                            : () => scope.follows.toggle(
                                  seriesId: series.id,
                                  title: series.title,
                                  coverUrl: series.coverUrl,
                                  episodeCount: series.episodeCount,
                                ),
                        tooltip: following ? '取消追剧' : '追剧',
                        icon: Icon(
                          following
                              ? AppIcons.favorite
                              : AppIcons.favoriteBorder,
                          color: following ? Colors.pinkAccent : null,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        // 右上：换一部 + 提示。
        Positioned(
          top: MediaQuery.paddingOf(context).top + 12,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FilledButton.tonalIcon(
                onPressed: onSkip,
                icon: const Icon(Icons.casino_outlined, size: 18),
                label: const Text('换一部'),
                style: FilledButton.styleFrom(
                  backgroundColor: PlayerOverlayTokens.hudFill,
                  foregroundColor: PlayerOverlayTokens.textPrimary,
                ),
              ),
              AppGap.v(AppGapSize.s8),
              Container(
                padding: const EdgeInsets.fromLTRB(AppSpacing.s8, AppSpacing.s6, AppSpacing.s8, AppSpacing.s6),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radiusLg)),
                ),
                child: const Text(
                  '随机看 · 上下滑换剧',
                  style: TextStyle(color: PlayerOverlayTokens.textSecondary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 播放条目视频；active（tab 可见）与 current（当前页）变化时播放/暂停。
class _ActiveVideo extends StatefulWidget {
  const _ActiveVideo(
      {required this.entry,
      required this.active,
      required this.current,
      required this.onSkip});

  final _FeedEntry entry;
  final bool active;
  final bool current;
  final VoidCallback onSkip;

  @override
  State<_ActiveVideo> createState() => _ActiveVideoState();
}

class _ActiveVideoState extends State<_ActiveVideo> {
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(covariant _ActiveVideo old) {
    super.didUpdateWidget(old);
    // 换条目（重试）：旧条目的错误态/加载态必须重置，否则新条目直接顶着一张错误卡。
    if (!identical(widget.entry, old.entry)) {
      if (widget.active) _start();
      return;
    }
    if (!widget.active) {
      if (old.active) widget.entry.pause();
      return;
    }
    if (!old.active) {
      _start();
      return;
    }
    if (widget.current == old.current) return;
    if (widget.current) {
      widget.entry.play();
    } else {
      widget.entry.pause();
    }
  }

  Future<void> _start() async {
    if (!widget.active) return;
    final entry = widget.entry;
    // 先声明「想播」：ensurePlaying 在 open 完成时按这个意愿决定是否起播。
    if (widget.current) await entry.play();
    if (!mounted) return;
    setState(() {
      _error = null;
      _loading = !entry.isOpened;
    });
    try {
      final quality = AppScope.read(context).settings.defaultQuality;
      // 解析 / 打开都加超时，避免随机页一直停在转圈。
      await entry.ensurePlaying(quality).timeout(const Duration(seconds: 20));
      // 期间可能被滑走 / 切 tab / 被页面路由盖住：不再续播，避免回魂。
      // 意愿位被 pause() 清掉时（上一帧已滑走）也不能再调 play()，否则会把
      // 刚刚静音的页重新唤醒一帧。
      if (!mounted || !widget.active || !widget.current || !entry.isWanted) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      await entry.play();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('这一部暂时放不了',
                style: TextStyle(color: PlayerOverlayTokens.textSecondary)),
            AppGap.v(AppGapSize.s8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: _start,
                  child: const Text('重试',
                      style: PlayerOverlayTokens.stylePrimary),
                ),
                AppGap.h(AppGapSize.s12),
                OutlinedButton(
                  onPressed: widget.onSkip,
                  child: const Text('换一部',
                      style: PlayerOverlayTokens.stylePrimary),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => widget.entry.player.playOrPause(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(
              controller: widget.entry.controller,
              controls: NoVideoControls),
          if (_loading)
            const Center(
              child: AppLoading(color: PlayerOverlayTokens.textPrimary),
            ),
        ],
      ),
    );
  }
}

/// 随机页的取流路线：与播放器页保持一致，官网 play-info（DASH 双轨）优先，
/// 失败或空流才回落旧 App 取流接口。
///
/// 旧接口自 2026-10-15 起对第三方客户端返回空 body（`anonymous response was
/// empty`）。随机页此前只走旧接口，所以整池 100% 报 `PLAYBACK_UNAVAILABLE`，
/// 而手动搜索播放走的是 webplay → 能正常开播——这就是「随机看不了、手动能看」
/// 的真正分叉点（2026-11-17 实测日志 5/5 部均空响应）。
Future<PlaybackResult> _resolveFeedPlayback(
  AquaApi api,
  String seriesId,
  String episodeId,
  String quality,
) async {
  // 官网通道的清晰度只认 480p / 720p 两档；随机页没有清晰度选择，按默认档映射。
  final definition = quality == '480p' || quality == 'worst' ? '480p' : '720p';
  try {
    final web = await api.resolvePlaybackWeb(
      seriesId,
      episodeId,
      definition: definition,
    );
    if (web.playback.streams.isNotEmpty) return web;
  } catch (e, st) {
    // 游客墙（未登录仅前 5 集）：回落旧接口也不会恢复，直接把准确错误交给上层。
    if (e is AquaException && e.code == AquaCode.webLoginRequired) rethrow;
    ErrorLog.instance.record('随机播放', 'webplay 取流失败，回落旧接口：$e', st);
  }
  return api.resolvePlayback(episodeId);
}
