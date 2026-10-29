import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/player/player_engine.dart';
import '../core/cast/cast_controller.dart';
import '../core/bili/api.dart';
import '../core/error_log.dart';
import '../core/sources/parse_engine.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_import.dart';
import '../widgets/cast_panel.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';

/// 分集播放地址解析钩子：bili:// 协议等需要播放时现解析的源提供。
class ResolvedPlay {
  const ResolvedPlay({required this.videoUrl, this.audioUrl, this.notice});
  final String videoUrl;
  final String? audioUrl;
  final String? notice;
}

typedef EpisodePlayResolver = Future<ResolvedPlay> Function(
    UnifiedEpisode episode);

/// 第三方源轻量播放器：mpv 直链播放（Media httpHeaders 支持 Referer/UA），
/// 每 5 秒回写历史（sourceKey 区分来源），失败自动换线（先线路后源由上层处理）。
/// [resolvePlay] 提供时支持 DASH 音视频双轨（mpv audio-files，BiliSail 同方案）
/// 与弹幕（[loadDanmaku]）。
class SourcePlayerScreen extends StatefulWidget {
  const SourcePlayerScreen({
    super.key,
    required this.source,
    required this.series,
    required this.line,
    required this.startIndex,
    required this.adapter,
    this.resolvePlay,
    this.loadDanmaku,
  });

  final SourceConfig source;
  final UnifiedSeries series;
  final PlayLine line;
  final int startIndex;
  final SourceAdapter adapter;
  final EpisodePlayResolver? resolvePlay;
  final Future<List<DanmakuItem>> Function(UnifiedEpisode episode)? loadDanmaku;

  @override
  State<SourcePlayerScreen> createState() => _SourcePlayerScreenState();
}

class _SourcePlayerScreenState extends State<SourcePlayerScreen> {
  late final PlayerEngine _engine;
  int _index = 0;

  /// 当前线路（失败自动换线：先线路后交还上层换源）。
  int _lineIndex = 0;
  int _autoSwitchCount = 0;
  String? _error;
  bool _loading = true;

  PlayLine get _line {
    final lines = widget.series.lines;
    return lines[_lineIndex.clamp(0, lines.length - 1)];
  }

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  List<DanmakuItem> _danmaku = const [];
  bool _danmakuEnabled = true;
  bool _playing = false;
  bool _buffering = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _historyTimer;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _bufferingSub;

  @override
  void initState() {
    super.initState();
    _lineIndex = widget.series.lines.indexOf(widget.line);
    if (_lineIndex < 0) _lineIndex = 0;
    _index = widget.startIndex.clamp(0, _line.episodes.length - 1);
    _engine = MpvPlayerEngine();
    castController.onRemoteStopped = (device, position) {
      if (!mounted) return;
      final behavior =
          AppScope.read(context).settings.castDisconnectBehavior;
      if (behavior != 'resumeLocal') return;
      if (position > Duration.zero) {
        _engine.seek(position);
      }
      _engine.play();
      setState(() {});
    };
    _open();
    _historyTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _recordHistory(finished: false));
  }

  @override
  void dispose() {
    castController.onRemoteStopped = null;
    _recordHistory(finished: false);
    _historyTimer?.cancel();
    _hideTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _bufferingSub?.cancel();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final ep = _line.episodes[_index];
    // async 间隙不再读 context：jx 解析接口在开头取好。
    final jxParses = AppScope.read(context).marketSites.parses;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var url = ep.url;
      String? audioUrl;
      List<DanmakuItem> danmaku = const [];
      // 播放时解析钩子（B 站等 DASH 双轨源）。
      if (widget.resolvePlay != null) {
        final resolved = await widget.resolvePlay!(ep);
        if (!mounted) return;
        // resolved 携带的提示只进状态条，无需 context。
        url = resolved.videoUrl;
        audioUrl = resolved.audioUrl;
        if (resolved.notice != null && mounted) {
          setState(() => _error = resolved.notice);
        }
        if (widget.loadDanmaku != null) {
          try {
            danmaku = await widget.loadDanmaku!(ep);
          } catch (_) {
            danmaku = const [];
          }
        }
      }
      // 音轨分离：mpv audio-files 选项在 loadfile 前设置才生效。
      await _engine.initialize();
      await _engine.setProperty(
          'audio-files', audioUrl ?? '');
      // jx：非直链地址先走解析接口（配置里的 type=1 parse）。
      if (!ParseEngine.isDirectMedia(url) && jxParses.isNotEmpty) {
        final parsed =
            await ParseEngine().resolve(url, parses: jxParses);
        if (parsed != null) url = parsed.url;
      }
      await _engine.open(Media(url, httpHeaders: _headers()));
      _subscribe();
      _danmaku = danmaku;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = true;
      });
      _armHideTimer();
      _recordHistory(finished: false);
    } catch (e) {
      ErrorLog.instance.record('源播放', e, StackTrace.current);
      if (!mounted) return;
      // 自动换线：同源还有下一条线路就切过去重试（xiugou-tv 语义简化版）。
      if (_autoSwitchCount < widget.series.lines.length - 1 &&
          _lineIndex + 1 < widget.series.lines.length) {
        _autoSwitchCount++;
        setState(() {
          _lineIndex++;
          _index = 0;
        });
        await _open();
        return;
      }
      setState(() {
        _loading = false;
        _error = '播放失败：$e（可回详情页换线路/换源）';
      });
    }
  }

  Map<String, String> _headers() {
    final h = Map.of(widget.source.headers);
    if (!h.containsKey('User-Agent')) {
      h['User-Agent'] = SourceImporter.defaultUa;
    }
    return h;
  }

  void _subscribe() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _bufferingSub?.cancel();
    _posSub = _engine.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = _engine.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _playingSub = _engine.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
    });
    _bufferingSub = _engine.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _buffering = v);
    });
    _completedSub = _engine.stream.completed.listen((completed) {
      if (!mounted || !completed) return;
      _recordHistory(finished: true);
      if (_index < _line.episodes.length - 1) {
        setState(() => _index++);
        _open();
      }
    });
  }

  Future<void> _recordHistory({required bool finished}) async {
    final ep = _line.episodes[_index];
    await AppScope.read(context).history.record(
          seriesId: widget.series.historyKey,
          title: widget.series.title,
          coverUrl: widget.series.coverUrl,
          episode: ep.index,
          episodes: _line.episodes.length,
          episodeId: ep.url,
          position: _position.inMilliseconds.toDouble(),
          finished: finished,
          sourceKey: widget.source.id,
        );
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  // ---------- 投屏（DLNA 发送端） ----------

  Future<void> _openCastSheet() async {
    final ep = _line.episodes[_index];
    final media = CastMedia(
      url: ep.url,
      title: '${widget.series.title} · ${ep.title}',
      position: _position,
      episodeIndex: ep.index,
      episodeCount: _line.episodes.length,
    );
    final result = await showCastSheet(
      context,
      media: media,
      onLocalPause: () => _engine.pause(),
    );
    if (!mounted || result == null) return;
    if (result == 'disconnect') {
      final position = await castController.disconnect();
      if (!mounted) return;
      final behavior =
          AppScope.read(context).settings.castDisconnectBehavior;
      if (behavior == 'resumeLocal' && position > Duration.zero) {
        await _engine.seek(position);
        await _engine.play();
        if (mounted) setState(() {});
      }
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHideTimer();
  }

  Future<void> _switchEpisode(int index) async {
    setState(() => _index = index.clamp(0, widget.line.episodes.length - 1));
    await _open();
  }

  @override
  Widget build(BuildContext context) {
    final ep = _line.episodes[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showControls
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Text('${widget.series.title} · ${ep.title}',
                  style: const TextStyle(fontSize: 16)),
              actions: [
                ListenableBuilder(
                  listenable: castController,
                  builder: (context, _) => IconButton(
                    tooltip: '投屏',
                    icon: Icon(castController.isCasting
                        ? Icons.cast_connected
                        : Icons.cast_outlined),
                    onPressed: _openCastSheet,
                  ),
                ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          children: [
            Center(
              child: Video(controller: _engine.videoController),
            ),
            Positioned.fill(
              child: DanmakuOverlay(
                items: _danmaku,
                position: _position,
                enabled: _danmakuEnabled && _playing,
              ),
            ),
            if (_loading)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style:
                            const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _open,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (_showControls) ...[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(_playing
                                  ? Icons.pause
                                  : Icons.play_arrow),
                              color: Colors.white,
                              tooltip: _playing ? '暂停' : '播放',
                              onPressed: () => _engine.playOrPause(),
                            ),
                            Text(
                              '${_format(_position)} / ${_format(_duration)}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                            const Spacer(),
                            if (_buffering)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70),
                              ),
                            ListenableBuilder(
                              listenable: castController,
                              builder: (context, _) => IconButton(
                                tooltip: _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
                                icon: Icon(
                                  Icons.subtitles_outlined,
                                  color: _danmakuEnabled
                                      ? Colors.white
                                      : Colors.white38,
                                ),
                                onPressed: () =>
                                    setState(() => _danmakuEnabled = !_danmakuEnabled),
                              ),
                            ),
                            IconButton(
                              tooltip: '上一集',
                              icon: const Icon(Icons.skip_previous,
                                  color: Colors.white),
                              onPressed: _index > 0
                                  ? () => _switchEpisode(_index - 1)
                                  : null,
                            ),
                            IconButton(
                              tooltip: '下一集',
                              icon: const Icon(Icons.skip_next,
                                  color: Colors.white),
                              onPressed:
                                  _index < _line.episodes.length - 1
                                      ? () => _switchEpisode(_index + 1)
                                      : null,
                            ),
                          ],
                        ),
                        SizedBox(
                          height: 28,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: _duration.inMilliseconds <= 0
                                  ? 0
                                  : _position.inMilliseconds
                                      .clamp(0, _duration.inMilliseconds)
                                      .toDouble(),
                              max: _duration.inMilliseconds
                                      .toDouble()
                                      .clamp(1, double.maxFinite),
                              onChanged: (v) {
                                _engine.seek(Duration(milliseconds: v.toInt()));
                              },
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 36,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final e in _line.episodes)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: e.index == ep.index
                                      ? FilledButton.tonal(
                                          onPressed: () {},
                                          child: Text(e.title,
                                              style: const TextStyle(
                                                  fontSize: 12)))
                                      : OutlinedButton(
                                          onPressed: () =>
                                              _switchEpisode(e.index - 1),
                                          child: Text(e.title,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white70)),
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
            ],
          ],
        ),
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
