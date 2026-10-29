import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
// media_kit 也有 AudioTrack（音轨选择用），这里用本项目的 AudioTrack。
import 'package:media_kit/media_kit.dart' hide AudioTrack;

import '../core/aqua_error.dart';
import '../core/player/player_engine.dart';
import '../models/audio.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/common.dart';

/// 听书页：选音色 → 播当前章 → 章节列表。
///
/// 播放走 mpv（与短剧播放器同一内核）：加密音轨把内容密钥交给
/// `demuxer-lavf-o` 的 `decryption_key` 解密。
class BookAudioScreen extends StatefulWidget {
  const BookAudioScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.chapters,
    this.coverUrl = '',
    this.startIndex = 0,
  });

  final String bookId;
  final String bookTitle;
  final String coverUrl;
  final List<BookChapter> chapters;
  final int startIndex;

  @override
  State<BookAudioScreen> createState() => _BookAudioScreenState();
}

class _BookAudioScreenState extends State<BookAudioScreen> {
  final PlayerEngine _engine = MpvPlayerEngine();

  AudioTones? _tones;
  AudioTone? _tone;
  AudioStream? _track;
  Object? _error;
  bool _loadingTones = true;
  bool _loadingTrack = false;
  bool _playing = false;

  /// 语速（番茄的听书语速 = 播放倍速）与自动连播。
  static const _speedKey = 'listen.speed';
  static const _autoNextKey = 'listen.autoNext';
  double _speed = 1.0;
  bool _autoNext = true;
  StreamSubscription<bool>? _doneSub;

  /// 听书进度（独立存储，与阅读进度不冲突）。
  StreamSubscription<Duration>? _posSub;
  Timer? _saveTimer;
  int _resumeMs = 0;
  StreamSubscription<String>? _errSub;
  String _playError = '';
  ListenEntry? _record;
  late int _index = widget.startIndex.clamp(0, _maxIndex);

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  @override
  void initState() {
    super.initState();
    final rec = AppScope.read(context).listening.entry(widget.bookId);
    _record = rec;
    if (rec != null) {
      _index = rec.chapterIndex.clamp(0, _maxIndex);
      _resumeMs = rec.positionMs;
    }
    _errSub = _engine.stream.error.listen((e) {
      if (!mounted) return;
      setState(() => _playError = e.toString());
    });
    _posSub = _engine.stream.position.listen((_) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 5), _saveProgress);
    });
    _loadPrefs();
    _doneSub = _engine.stream.completed.listen((done) {
      if (!done || !_autoNext || _index >= _maxIndex) return;
      _go(1);
    });
    _loadTones();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _posSub?.cancel();
    _doneSub?.cancel();
    _errSub?.cancel();
    _saveProgress();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _loadTones() async {
    try {
      final tones = await AppScope.read(context).api.audioTones(widget.bookId);
      if (!mounted) return;
      setState(() {
        _tones = tones;
        final saved = _record?.toneId ?? 0;
        final match = tones.tones.where((x) => x.id == saved).toList();
        _tone = match.isNotEmpty
            ? match.first
            : (tones.tones.isEmpty ? null : tones.tones.first);
        _loadingTones = false;
      });
      if (_tone != null) await _playCurrent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loadingTones = false;
      });
    }
  }

  Future<void> _playCurrent() async {
    final tone = _tone;
    if (tone == null) return;
    setState(() {
      _loadingTrack = true;
      _error = null;
    });
    try {
      final track = await AppScope.read(context)
          .api
          .audioStream(widget.bookId, _chapter.id, tone.id);
      if (!mounted) return;
      setState(() {
        _track = track;
        _loadingTrack = false;
      });
      await _open(track);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loadingTrack = false;
      });
    }
  }

  Future<void> _open(AudioStream track) async {
    if (!track.isPlayable) return;
    final lavf = [
      'seg_max_retry=3',
      'strict=experimental',
      'allowed_extensions=ALL',
      'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
      if (track.keyHex.isNotEmpty) 'decryption_key=${track.keyHex}',
    ].join(',');
    // CDN（qznovelvod）只认阅读客户端的 UA + Referer，其它一律 403；
    // mpv 默认没有这两个头，拉流会 403、进度不动，所以随 Media 一起传。
    await _engine.setProperty('demuxer-lavf-o', lavf);
    // 双保险：Media 带 httpHeaders；若 mpv 支持该属性再显式设一次。
    try {
      await _engine.setProperty(
        'http-header-fields',
        'User-Agent: com.dragon.read,Referer: https://reading.snssdk.com/',
      );
    } catch (_) {
      // 该属性不可用时忽略，Media 的 httpHeaders 仍会带上请求头。
    }
    await _engine.open(Media(track.path), play: true);
    await _engine.setRate(_speed);
    if (_resumeMs > 0) {
      await _engine.seek(Duration(milliseconds: _resumeMs));
      _resumeMs = 0;
    }
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _toggle() async {
    if (_track == null) {
      await _playCurrent();
      return;
    }
    await _engine.playOrPause();
    if (mounted) setState(() => _playing = !_playing);
  }

  Future<void> _go(int delta) async {
    final next = (_index + delta).clamp(0, _maxIndex);
    if (next == _index) return;
    await _saveProgress();
    _resumeMs = 0;
    setState(() => _index = next);
    await _playCurrent();
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.bookTitle)),
      body: _loadingTones
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && _tones == null)
              ? ErrorRetryView(error: _error!, onRetry: _loadTones)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 16),
                    _buildPlayer(context),
                    const SizedBox(height: 20),
                    Text('章节', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final chapter in widget.chapters)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          chapter.index == _index
                              ? Icons.graphic_eq
                              : Icons.play_circle_outline,
                          size: 18,
                          color: chapter.index == _index
                              ? theme.colorScheme.primary
                              : null,
                        ),
                        title: Text(chapter.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          setState(() => _index = chapter.index);
                          _playCurrent();
                        },
                      ),
                  ],
                ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final tones = _tones;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 64,
            height: 86,
            child: CoverImage(url: widget.coverUrl),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.bookTitle,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Text(
                tones == null || tones.isEmpty
                    ? '这本书暂不支持听书'
                    : (tones.hasRecordedAudio ? '有声书 · 真人讲书' : '智能朗读'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if (_record != null && _record!.chapterTitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('上次听到 · ${_record!.chapterTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              ],
              if (tones != null && tones.tones.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final tone in tones.tones)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: tone.icon.isEmpty
                                ? null
                                : CircleAvatar(
                                    backgroundImage: NetworkImage(tone.icon)),
                            label: Text(tone.title),
                            selected: _tone?.id == tone.id,
                            onSelected: (_) {
                              setState(() => _tone = tone);
                              _playCurrent();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(_chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: _index > 0 ? () => _go(-1) : null,
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: FilledButton(
                    onPressed: _tone == null ? null : _toggle,
                    style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero),
                    child: _loadingTrack
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: _index < _maxIndex ? () => _go(1) : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
            children: [
              const Text('语速'),
              Expanded(
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  label: '${_speed.toStringAsFixed(2)}x',
                  onChanged: (v) {
                    setState(() => _speed = v);
                    // ignore: discarded_futures
                    _engine.setRate(v);
                    // ignore: discarded_futures
                    _savePrefs();
                  },
                ),
              ),
              SizedBox(
                width: 46,
                child: Text('${_speed.toStringAsFixed(2)}x',
                    style: theme.textTheme.labelSmall),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('自动连播'),
            subtitle: const Text('这一章播完自动播下一章'),
            value: _autoNext,
            onChanged: (v) {
              setState(() => _autoNext = v);
              // ignore: discarded_futures
              _savePrefs();
            },
          ),
          StreamBuilder<Duration>(
              stream: _engine.stream.position,
              builder: (context, pos) {
                return StreamBuilder<Duration>(
                  stream: _engine.stream.duration,
                  builder: (context, dur) {
                    final position = pos.data ?? Duration.zero;
                    final duration = dur.data ?? Duration.zero;
                    final maxMs = duration.inMilliseconds.toDouble();
                    final value = maxMs > 0
                        ? (position.inMilliseconds / maxMs).clamp(0.0, 1.0)
                        : 0.0;
                    return Column(
                      children: [
                        Slider(
                          value: value,
                          onChanged: maxMs <= 0
                              ? null
                              : (v) => _engine.seek(Duration(
                                  milliseconds: (v * maxMs).round())),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(position),
                                  style: theme.textTheme.labelSmall),
                              Text(_fmt(duration),
                                  style: theme.textTheme.labelSmall),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            if (_playError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_playError,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error is AquaException
                      ? (_error! as AquaException).friendlyText
                      : '这一章暂时听不了',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _speed = (prefs.getDouble(_speedKey) ?? 1.0).clamp(0.5, 2.0);
        _autoNext = prefs.getBool(_autoNextKey) ?? true;
      });
    } catch (_) {
      // 偏好读不到就用默认值。
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_speedKey, _speed);
      await prefs.setBool(_autoNextKey, _autoNext);
    } catch (_) {
      // 偏好写失败不影响播放。
    }
  }

  /// 写入听书进度（章节 + 章内位置）。
  Future<void> _saveProgress() async {
    if (!mounted) return;
    try {
      await AppScope.read(context).listening.record(
        bookId: widget.bookId,
        title: widget.bookTitle,
        coverUrl: widget.coverUrl,
        chapterId: _chapter.id,
        chapterTitle: _chapter.title,
        chapterIndex: _index,
        chapters: widget.chapters.length,
        toneId: _tone?.id ?? 0,
        positionMs: _engine.state.position.inMilliseconds,
      );
    } catch (_) {
      // 进度写入失败不影响播放。
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
