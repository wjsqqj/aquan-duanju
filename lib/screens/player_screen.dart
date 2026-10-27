import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/aqua_error.dart';
import '../models/models.dart';
import '../widgets/common.dart';

/// 播放器页。
///
/// 播放链路：resolvePlayback 选流 → 受保护流带 contentKey 经 mpv 的
/// demuxer-lavf-o decryption_key 解密（与 guoappxxx 验证过的方案一致）→
/// 完结/手势切换上下集 → 每 5 秒回写本地历史。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.series,
    required this.episodes,
    required this.startIndex,
    this.startAt = Duration.zero,
  });

  final Series series;
  final List<Episode> episodes;
  final int startIndex;
  final Duration startAt;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  bool _prepared = false;
  bool _disposed = false;

  int _index = 0;
  PlaybackResult? _playback;
  String? _selectedDefinition;
  List<String> _definitions = const [];
  double _speed = 1.0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _historyTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _completedSub;

  // 手势状态。
  double _lastBrightness = 0.5;
  double? _dragStartPos;
  double? _dragStartVolume;
  double? _dragStartBrightness;
  _DragKind? _dragKind;
  double? _seekPreviewMs;
  double? _overlayValue;

  Object? _loadError;
  bool _loadingStream = true;

  bool get _isWide => MediaQuery.sizeOf(context).width > 700;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex.clamp(0, widget.episodes.length - 1);
    _speed = double.tryParse(AppScope.read(context).settings.defaultSpeed) ?? 1.0;
    _player = Player();
    _controller = VideoController(_player);
    _installMpvOptions();
    _posSub = _player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = _player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _completedSub = _player.stream.completed.listen((completed) {
      if (completed) _onEnded();
    });
    _historyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_position > Duration.zero) _recordHistory(finished: false);
    });
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _openEpisode(_index, widget.startAt);
  }

  /// mpv 全局参数：解密、协议白名单、硬件解码、超时。
  void _installMpvOptions() {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    p.setProperty('network-timeout', '20');
    p.setProperty('cache', 'yes');
    p.setProperty('demuxer-max-bytes', '64MiB');
    p.setProperty('force-seekable', 'yes');
    // Windows d3d11va / Android mediacodec。
    p.setProperty('hwdec', Platform.isAndroid ? 'mediacodec' : 'd3d11va-copy');
  }


  @override
  void dispose() {
    _recordHistory(finished: false);
    _historyTimer?.cancel();
    _hideTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _player.dispose();
    _disposed = true;
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _restoreOrientation();
    super.dispose();
  }

  void _restoreOrientation() {
    if (widget.episodes[_index.clamp(0, widget.episodes.length - 1)].vertical &&
        !_isWide) {
      // 竖屏剧恢复竖屏；横屏剧保持允许旋转。
    }
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  Future<void> _openEpisode(int index, Duration startAt) async {
    final ep = widget.episodes[index];
    setState(() {
      _loadingStream = true;
      _loadError = null;
      _playback = null;
      _selectedDefinition = null;
      _definitions = const [];
    });
    try {
      final scope = AppScope.read(context);
      final api = scope.api;
      final quality = scope.settings.defaultQuality;
      final pb = await api.resolvePlayback(ep.id);
      if (_disposed) return;
      if (pb.playback.streams.isEmpty) {
        throw AquaException(
            code: AquaCode.contentUnavailable,
            message: '没有可用播放流',
            retryable: false);
      }
      final stream = _selectStream(pb.playback, quality);
      setState(() {
        _playback = pb;
        _definitions = _definitionLabels(pb.playback);
        _selectedDefinition = _definitionLabel(stream);
        _loadingStream = false;
        _index = index;
      });
      await _playStream(stream, startAt);
      _recordHistory(finished: false);
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _loadError = e;
        _loadingStream = false;
      });
    }
  }

  /// 与 SDK Playback.Select 相同语义的选流：best/worst/具体清晰度标签。
  VideoStream _selectStream(Playback pb, String quality) {
    final usable =
        pb.streams.where((s) => s.url.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw AquaException(
          code: AquaCode.contentUnavailable,
          message: '没有可用播放流',
          retryable: false);
    }
    int rank(VideoStream s) {
      if (s.height > 0) return s.height;
      final digits = RegExp(r'^(\d+)').firstMatch(s.definition)?.group(1);
      return digits == null ? 0 : int.parse(digits);
    }

    usable.sort((a, b) {
      final ra = rank(a);
      final rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      return a.bitrate.compareTo(b.bitrate);
    });
    switch (quality) {
      case 'worst':
        return usable.first;
      case '':
      case 'best':
        return usable.last;
      default:
        return usable.lastWhere(
          (s) =>
              s.definition == quality ||
              s.quality == quality ||
              s.codec == quality,
          orElse: () => usable.last,
        );
    }
  }

  List<String> _definitionLabels(Playback pb) {
    final set = <String>{};
    for (final s in pb.streams) {
      if (s.url.isEmpty) continue;
      set.add(_definitionLabel(s));
    }
    return set.toList();
  }

  String _definitionLabel(VideoStream s) =>
      s.definition.isNotEmpty ? s.definition : (s.quality.isEmpty ? '默认' : s.quality);

  Future<void> _playStream(VideoStream stream, Duration startAt) async {
    final p = _player.platform;
    if (p is NativePlayer) {
      final pb = _playback!;
      final key = pb.contentKey?.key ?? '';
      final lavf = [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (key.isNotEmpty) 'decryption_key=$key',
      ].join(',');
      await p.setProperty('demuxer-lavf-o', lavf);
    }
    await _player.setRate(_speed);
    await _player.open(Media(stream.url), play: true);
    if (startAt > Duration.zero) {
      await _player.seek(startAt);
    }
    setState(() => _prepared = true);
  }

  Future<void> _switchDefinition(String label) async {
    final pb = _playback;
    if (pb == null) return;
    final stream = pb.playback.streams.firstWhere(
      (s) => s.url.isNotEmpty && _definitionLabel(s) == label,
      orElse: () => pb.playback.streams.first,
    );
    final resumeAt = _position;
    setState(() => _selectedDefinition = label);
    await _playStream(stream, resumeAt);
  }

  void _onEnded() {
    if (!_disposed) _recordHistory(finished: true);
    if (AppScope.read(context).settings.autoNext) {
      _goNext();
    }
  }

  void _goNext() {
    if (_index < widget.episodes.length - 1) {
      _openEpisode(_index + 1, Duration.zero);
    } else {
      _showToast('已经是最后一集了');
    }
  }

  void _goPrev() {
    if (_index > 0) {
      _openEpisode(_index - 1, Duration.zero);
    } else {
      _showToast('已经是第一集了');
    }
  }

  Future<void> _recordHistory({required bool finished}) async {
    final scope = AppScope.read(context);
    if (widget.series.id.isEmpty) return;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    await scope.history.record(
      seriesId: widget.series.id,
      title: widget.series.title,
      coverUrl: widget.series.coverUrl,
      episode: ep.number,
      episodes: widget.episodes.length,
      episodeId: ep.id,
      position: finished ? 0 : _position.inSeconds.toDouble(),
      finished: finished,
    );
  }

  // ---------- 手势 ----------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _onHorizontalDragStart(DragStartDetails d) {
    _dragKind = _DragKind.seek;
    _dragStartPos = d.localPosition.dx;
    _seekPreviewMs = _position.inMilliseconds.toDouble();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (_dragKind != _DragKind.seek || _duration == Duration.zero) return;
    final delta = d.localPosition.dx - (_dragStartPos ?? 0);
    final ms = (_seekPreviewMs ?? 0) + delta * 300;
    setState(() {
      _overlayValue = ms.clamp(0.0, _duration.inMilliseconds.toDouble()).toDouble();
    });
  }

  void _onDragEnd(DragEndDetails d) async {
    if (_dragKind == _DragKind.seek) {
      final target = _overlayValue;
      if (target != null) {
        await _player.seek(Duration(milliseconds: target.floor()));
      }
      setState(() {
        _seekPreviewMs = null;
        _overlayValue = null;
      });
    } else if (_dragKind == _DragKind.brightness) {
      setState(() => _overlayValue = null);
    } else if (_dragKind == _DragKind.volume) {
      setState(() => _overlayValue = null);
    }
    _dragKind = null;
    _dragStartPos = null;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d, bool leftHalf) {
    _dragKind ??= leftHalf ? _DragKind.brightness : _DragKind.volume;
    if (_dragKind == _DragKind.brightness) {
      _dragStartBrightness ??= _lastBrightness;
      final delta = -d.delta.dy / 300;
      final v = ((_dragStartBrightness ?? 0.5) + delta).clamp(0.0, 1.0).toDouble();
      _lastBrightness = v;
      ScreenBrightness().setApplicationScreenBrightness(v);
      setState(() => _overlayValue = v);
    } else if (_dragKind == _DragKind.volume) {
      _dragStartVolume ??= _player.state.volume;
      final delta = -d.delta.dy / 2;
      final v = ((_dragStartVolume ?? 100) + delta).clamp(0.0, 100.0);
      _player.setVolume(v);
      setState(() => _overlayValue = v);
    }
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(milliseconds: 800)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (d) {
              final half = MediaQuery.sizeOf(context).width / 2;
              if (d.localPosition.dx < half) {
                _player.seek(_position - const Duration(seconds: 10));
                _showToast('快退 10 秒');
              } else {
                _player.seek(_position + const Duration(seconds: 10));
                _showToast('快进 10 秒');
              }
            },
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onVerticalDragStart: (_) => _dragKind = null,
            onVerticalDragUpdate: (d) =>
                _onVerticalDragUpdate(d, d.localPosition.dx <
                    MediaQuery.sizeOf(context).width / 2),
            onVerticalDragEnd: _onDragEnd,
            child: _buildVideo(context),
          ),
          if (_overlayValue != null) _buildGestureOverlay(context),
          if (_loadingStream) const Center(child: CircularProgressIndicator()),
          if (_loadError != null) _buildLoadError(context),
          if (_showControls) _buildControls(context),
        ],
      ),
    );
  }

  Widget _buildVideo(BuildContext context) {
    if (!_prepared) {
      return Container(color: Colors.black);
    }
    return Video(
      controller: _controller,
      controls: NoVideoControls,
    );
  }

  Widget _buildLoadError(BuildContext context) {
    final e = _loadError!;
    final text =
        e is AquaException ? e.friendlyText : '加载失败，请稍后再试';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () => _openEpisode(_index, Duration.zero),
                child: const Text('重试',
                    style: TextStyle(color: Colors.white)),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGestureOverlay(BuildContext context) {
    final v = _overlayValue!;
    final text = switch (_dragKind) {
      _DragKind.seek =>
        '${_fmtDur(Duration(milliseconds: v.floor()))} / ${_fmtDur(_duration)}',
      _DragKind.brightness => '亮度 ${(v * 100).round()}%',
      _DragKind.volume => '音量 ${v.round()}%',
      null => '',
    };
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final ep = widget.episodes[_index];
    return GestureDetector(
      onTap: _toggleControls,
      child: Container(
        color: Colors.black26,
        child: Column(
          children: [
            // 顶栏
            SafeArea(
              bottom: false,
              child: Row(
                children: [
                  const BackButton(color: Colors.white),
                  Expanded(
                    child: Text(
                      '${widget.series.title} · ${ep.title.isEmpty ? '第${ep.number}集' : ep.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15),
                    ),
                  ),
                  if (_definitions.length > 1)
                    PopupMenuButton<String>(
                      initialValue: _selectedDefinition,
                      color: Colors.grey.shade900,
                      onSelected: _switchDefinition,
                      itemBuilder: (_) => [
                        for (final d in _definitions)
                          PopupMenuItem(
                              value: d,
                              child: Text(d,
                                  style: const TextStyle(
                                      color: Colors.white))),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(_selectedDefinition ?? '清晰度',
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
            const Spacer(),
            // 底栏
            SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Text(_fmtDur(_position),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: _duration == Duration.zero
                                  ? 0
                                  : _position.inMilliseconds
                                      .clamp(0, _duration.inMilliseconds)
                                      .toDouble(),
                              max: _duration.inMilliseconds
                                  .toDouble()
                                  .clamp(1, double.infinity),
                              onChanged: (v) =>
                                  _player.seek(Duration(milliseconds: v.floor())),
                            ),
                          ),
                        ),
                        Text(_fmtDur(_duration),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: _goPrev,
                        icon: const Icon(Icons.skip_previous,
                            color: Colors.white),
                      ),
                      IconButton(
                        onPressed: () => _player.playOrPause(),
                        icon: StreamBuilder<bool>(
                          stream: _player.stream.playing,
                          initialData: true,
                          builder: (_, snap) => Icon(
                            snap.data == true
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _goNext,
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                      ),
                      const Spacer(),
                      // 倍速
                      PopupMenuButton<double>(
                        initialValue: _speed,
                        color: Colors.grey.shade900,
                        onSelected: (v) async {
                          setState(() => _speed = v);
                          await _player.setRate(v);
                        },
                        itemBuilder: (_) => [
                          for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                            PopupMenuItem(
                                value: v,
                                child: Text('${v}x',
                                    style: const TextStyle(
                                        color: Colors.white))),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text('${_speed}x',
                              style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                      // 全屏切换
                      IconButton(
                        onPressed: () async {
                          final isLandscape = MediaQuery.orientationOf(
                                  context) ==
                              Orientation.landscape;
                          if (isLandscape) {
                            _restoreOrientation();
                          } else {
                            await SystemChrome.setPreferredOrientations([
                              DeviceOrientation.landscapeLeft,
                              DeviceOrientation.landscapeRight,
                            ]);
                          }
                        },
                        icon: const Icon(Icons.fullscreen,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DragKind { seek, brightness, volume }

String _fmtDur(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
