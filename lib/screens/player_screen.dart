import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../core/aqua_error.dart';
import '../core/playback_utils.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/download_sheet.dart';
import '../widgets/episode_picker.dart';

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
  Timer? _sleepTimer;
  int _sleepMinutes = 0;

  /// 当前播放的流（备用容错用）；本地播放为 null。
  VideoStream? _currentVideoStream;
  bool _usedBackup = false;
  StreamSubscription<String>? _errorSub;

  /// 连播预解析：集下标 → 已解析的播放结果（本会话内复用）。
  final Map<int, PlaybackResult> _prefetched = {};

  double _lastBrightness = 0.5;
  double? _dragStartPos;
  double? _dragStartVolume;
  double? _dragStartBrightness;
  _DragKind? _dragKind;
  double? _seekPreviewMs;
  double? _overlayValue;

  Object? _loadError;
  bool _loadingStream = true;
  bool _fittedWindow = false;
  bool _muted = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    if (widget.episodes.isEmpty) {
      // 防御：调用方应保证非空；空列表直接报错态而不是崩溃。
      _loadingStream = false;
      _loadError = AquaException(
          code: AquaCode.contentUnavailable,
          message: '没有可播放的分集',
          retryable: false);
      return;
    }
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
    _errorSub = _player.stream.error.listen(_onPlaybackError);
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
    _sleepTimer?.cancel();
    _historyTimer?.cancel();
    _hideTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _player.dispose();
    _disposed = true;
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _restoreOrientation();
    super.dispose();
  }

  void _restoreOrientation() {
    if (_isDesktop) return;
    // 退出播放器后交还给系统，首页可自由旋转。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  /// 按片源方向自动摆正：竖屏剧竖着看，横屏剧横着看。
  void _applyOrientation(Episode episode) {
    if (_isDesktop) return;
    if (episode.vertical) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 桌面端首次打开视频时，把窗口调成和片源一致的比例（参考「自动摆正」）。
  Future<void> _maybeFitWindow(VideoStream stream, Episode episode) async {
    if (!_isDesktop || _fittedWindow) return;
    _fittedWindow = true;
    final settings = AppScope.read(context).settings;
    if (!settings.autoFitWindow) return;
    await _fitWindowToStream(stream, episode);
  }

  Future<void> _fitWindowToStream(VideoStream stream, Episode episode) async {
    if (!_isDesktop) return;
    try {
      if (await windowManager.isFullScreen() ||
          await windowManager.isMaximized()) {
        return;
      }
      final double aspect;
      if (stream.width > 0 && stream.height > 0) {
        aspect = stream.width / stream.height;
      } else {
        aspect = episode.vertical ? 9 / 16 : 16 / 9;
      }
      final bounds = await windowManager.getBounds();
      var height = bounds.height;
      if (height < 500) height = 760;
      var width = height * aspect;
      width = width.clamp(380.0, 1600.0);
      await windowManager.setBounds(Rect.fromLTWH(
        bounds.center.dx - width / 2,
        bounds.top,
        width,
        height,
      ));
    } catch (_) {}
  }

  Future<void> _toggleFullscreen() async {
    if (!_isDesktop) return;
    try {
      final full = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!full);
    } catch (_) {}
  }

  /// 桌面端键盘快捷键：空格暂停、←/→ 快进退 10 秒、↑/↓ 音量、
  /// F 全屏、M 静音、PageUp/PageDown 上下集、Esc 退出全屏/返回。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _player.playOrPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _player.seek(_position - const Duration(seconds: 10));
      _showToast('快退 10 秒');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _player.seek(_position + const Duration(seconds: 10));
      _showToast('快进 10 秒');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      final v = (_player.state.volume + 5).clamp(0.0, 100.0);
      _player.setVolume(v);
      _showToast('音量 ${v.round()}%');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final v = (_player.state.volume - 5).clamp(0.0, 100.0);
      _player.setVolume(v);
      _showToast('音量 ${v.round()}%');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _muted = !_muted;
      _player.setVolume(_muted ? 0 : 100);
      _showToast(_muted ? '已静音' : '取消静音');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE) {
      _openEpisodePicker();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f1) {
      _showShortcutHelp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _goNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _goPrev();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_isDesktop) {
        windowManager.isFullScreen().then((full) {
          if (full) windowManager.setFullScreen(false);
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
    // 已缓存的集直接播本地文件（带密钥解密），不发起任何网络请求。
    final local = AppScope.read(context).downloads.localEntryOf(ep.id);
    if (local != null) {
      if (_disposed) return;
      setState(() {
        _playback = null;
        _definitions = local.keyHex.isEmpty ? const [] : const ['本地'];
        _selectedDefinition = local.keyHex.isEmpty ? null : '本地';
        _loadingStream = false;
        _index = index;
      });
      await _playLocal(local, startAt);
      _applyOrientation(ep);
      _recordHistory(finished: false);
      return;
    }
    try {
      final scope = AppScope.read(context);
      final api = scope.api;
      final quality = scope.settings.defaultQuality;
      // 连播预解析命中直接用（过期则重新解析），换集零等待。
      final cached = _prefetched.remove(index);
      final pb = cached != null && prefetchUsable(cached, DateTime.now())
          ? cached
          : await api.resolvePlayback(ep.id);
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
      _applyOrientation(ep);
      await _maybeFitWindow(stream, ep);
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

  VideoStream _currentStream(Playback pb) {
    final label = _selectedDefinition;
    if (label != null) {
      for (final stream in pb.streams) {
        if (stream.url.isNotEmpty && _definitionLabel(stream) == label) {
          return stream;
        }
      }
    }
    return pb.streams.firstWhere((s) => s.url.isNotEmpty,
        orElse: () => pb.streams.first);
  }

  Future<void> _playStream(VideoStream stream, Duration startAt) async {
    _currentVideoStream = stream;
    _usedBackup = false;
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
    _prefetchNext(_index);
  }

  /// 当前集开播后预解析下一集；静默失败（离线/限流都不影响当前播放）。
  void _prefetchNext(int index) {
    final next = index + 1;
    if (next >= widget.episodes.length) return;
    if (_prefetched.containsKey(next)) return;
    final ep = widget.episodes[next];
    if (!ep.playable) return;
    AppScope.read(context).api.resolvePlayback(ep.id).then((pb) {
      if (_disposed) return;
      _prefetched[next] = pb;
    }, onError: (_) {});
  }

  /// 播放器报错：主地址失败自动改用备用地址重开一次，仍失败进错误态。
  Future<void> _onPlaybackError(String error) async {
    if (_disposed) return;
    final stream = _currentVideoStream;
    if (stream == null || _usedBackup) return;
    final backup = stream.backupUrl;
    if (backup.isEmpty || backup == stream.url) return;
    _usedBackup = true;
    _showToast('播放失败，正在切换备用线路…');
    try {
      await _player.open(Media(backup), play: true);
    } catch (_) {
      if (!_disposed) _showToast('备用线路也不可用');
    }
  }

  /// 播放本地缓存文件：密钥为空说明未加密，直接播；否则带 decryption_key。
  Future<void> _playLocal(DownloadEntry entry, Duration startAt) async {
    _currentVideoStream = null;
    final p = _player.platform;
    if (p is NativePlayer) {
      final lavf = [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'protocol_whitelist=[file,http,https,tcp,tls,crypto,data]',
        if (entry.keyHex.isNotEmpty) 'decryption_key=${entry.keyHex}',
      ].join(',');
      await p.setProperty('demuxer-lavf-o', lavf);
    }
    await _player.setRate(_speed);
    await _player.open(Media(entry.filePath), play: true);
    if (startAt > Duration.zero) {
      await _player.seek(startAt);
    }
    if (!_disposed) setState(() => _prepared = true);
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

  /// 桌面快捷键自说明面板（F1）。
  void _showShortcutHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('键盘快捷键'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Shortcut(key_: '空格', action: '暂停 / 播放'),
            _Shortcut(key_: '← / →', action: '快退 / 快进 10 秒'),
            _Shortcut(key_: '↑ / ↓', action: '音量 +5% / -5%'),
            _Shortcut(key_: 'F', action: '全屏切换'),
            _Shortcut(key_: 'M', action: '静音'),
            _Shortcut(key_: 'E', action: '选集'),
            _Shortcut(key_: 'F1', action: '本帮助'),
            _Shortcut(key_: 'PgUp / PgDn', action: '上一集 / 下一集'),
            _Shortcut(key_: 'Esc', action: '退出全屏'),
          ],
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 睡眠定时：到点暂停播放；选「关」取消。
  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    if (!mounted) return;
    setState(() => _sleepMinutes = minutes);
    if (minutes <= 0) {
      _showToast('已取消睡眠定时');
      return;
    }
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (_disposed) return;
      _player.pause();
      _showToast('睡眠时间到，已暂停');
      if (mounted) setState(() => _sleepMinutes = 0);
    });
    _showToast('将在 $minutes 分钟后暂停');
  }

  /// 选集抽屉：点任意一集直接换集。
  Future<void> _openEpisodePicker() async {
    if (widget.episodes.isEmpty || _disposed) return;
    final downloads = AppScope.read(context).downloads;
    await showEpisodePicker(
      context,
      title: widget.series.title,
      episodes: widget.episodes,
      currentIndex: _index,
      onSelect: (i) {
        if (_disposed || i == _index) return;
        _openEpisode(i, Duration.zero);
      },
      isDownloaded: (ep) => downloads.store.has(ep.id),
      onDownload: () {
        Navigator.of(context).pop();
        showDownloadSheet(
          context,
          series: widget.series,
          episodes: widget.episodes,
        );
      },
    );
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
      // Linux 等平台没有亮度插件，失败时不打断播放。
      ScreenBrightness().setApplicationScreenBrightness(v).catchError((_) {});
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
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTapDown: (d) {
                if (_isDesktop) {
                  _toggleFullscreen();
                  return;
                }
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
                      // 选集：长剧不用退回详情页翻找。
                      IconButton(
                        tooltip: _isDesktop ? '选集 (E)' : '选集',
                        onPressed: _openEpisodePicker,
                        icon: const Icon(Icons.format_list_numbered,
                            color: Colors.white),
                      ),
                      const Spacer(),
                      // 睡眠定时
                      PopupMenuButton<int>(
                        tooltip: '睡眠定时',
                        initialValue: _sleepMinutes,
                        color: Colors.grey.shade900,
                        onSelected: _setSleepTimer,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 0,
                              child: Text('不定时',
                                  style: TextStyle(color: Colors.white))),
                          PopupMenuItem(
                              value: 15,
                              child: Text('15 分钟',
                                  style: TextStyle(color: Colors.white))),
                          PopupMenuItem(
                              value: 30,
                              child: Text('30 分钟',
                                  style: TextStyle(color: Colors.white))),
                          PopupMenuItem(
                              value: 60,
                              child: Text('60 分钟',
                                  style: TextStyle(color: Colors.white))),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            _sleepMinutes > 0
                                ? Icons.timer
                                : Icons.timer_outlined,
                            color: _sleepMinutes > 0
                                ? Colors.amberAccent
                                : Colors.white,
                          ),
                        ),
                      ),
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
                      // 桌面端：窗口调成片源比例；移动端：横竖屏切换。
                      if (_isDesktop)
                        IconButton(
                          tooltip: '适应片源',
                          onPressed: () {
                            final pb = _playback;
                            if (pb == null) return;
                            _fitWindowToStream(
                              _currentStream(pb.playback),
                              widget.episodes[_index],
                            );
                          },
                          icon: const Icon(Icons.aspect_ratio,
                              color: Colors.white),
                        ),
                      IconButton(
                        tooltip: _isDesktop ? '全屏 (F)' : '横屏/竖屏',
                        onPressed: () async {
                          if (_isDesktop) {
                            await _toggleFullscreen();
                            return;
                          }
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
                        icon: Icon(
                            _isDesktop
                                ? Icons.fullscreen
                                : Icons.screen_rotation,
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


/// 帮助面板里的一行：按键 + 说明。
class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.key_, required this.action});

  final String key_;
  final String action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(key_,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(action, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
