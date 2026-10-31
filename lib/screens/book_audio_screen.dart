import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
// media_kit 也有 AudioTrack（音轨选择用），这里用本项目的 AudioTrack。
import 'package:media_kit/media_kit.dart' hide AudioTrack;

import '../core/aqua_error.dart';
import '../core/player/player_engine.dart';
import '../core/reader/reader_listen_settings.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/reader/speech/chapter_gap.dart';
import '../core/reader/speech/chapter_prefetcher.dart';
import '../core/reader/speech/listen_media_bridge.dart';
import '../core/reader/speech/listen_media_state.dart';
import '../core/reader/speech/sleep_timer.dart';
import '../core/tts/tts_models.dart';
import '../models/audio.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/reader/follow_pill.dart';
import '../widgets/reader/sleep_sheet.dart';

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
    this.startRatio = 0,
    this.startParagraph = 0,
  });

  final String bookId;
  final String bookTitle;
  final String coverUrl;
  final List<BookChapter> chapters;
  final int startIndex;

  /// 从阅读进度换算的章内比例（0..1）：听书从该位置开始。
  final double startRatio;

  /// 读到的段落下标（用于时间点精确对齐）。
  final int startParagraph;

  @override
  State<BookAudioScreen> createState() => _BookAudioScreenState();
}

class _BookAudioScreenState extends State<BookAudioScreen>
    with WidgetsBindingObserver {
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

  /// 定时与预取接的是与控制器路径**同一对纯组件**（design §1：两条播放路径
  /// 各持实例，但实现只有一份）；持久化共用 `ReaderListenSettings`，本页不
  /// 新建 prefs 键，也不复制任何定时判定逻辑。音轨路径拿不到句边界 →
  /// `sentenceEndMs` 恒 null，到点只能整停（UI 如实注明）。
  final SleepTimer _sleep = SleepTimer(clockMs: _wallClockMs);
  final ChapterPrefetcher _prefetcher = ChapterPrefetcher();
  ReaderListenSettings? _listenSettings;

  /// 剩余时间的重建信号：由播放器位置流推进（每秒一跳）。本页不自建 Timer，
  /// 节拍来自媒体时间轴本身，暂停时位置不前进 → 浮层自然不倒数。
  final ValueNotifier<int> _sleepTick = ValueNotifier<int>(0);
  Duration _lastPos = Duration.zero;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 听书进度（独立存储，与阅读进度不冲突）。
  StreamSubscription<Duration>? _posSub;
  Timer? _saveTimer;
  Duration _lastSavedPos = Duration.zero;
  int _resumeMs = 0;
  StreamSubscription<String>? _errSub;
  String _playError = '';
  ListenEntry? _record;
  late int _index = widget.startIndex.clamp(0, _maxIndex);

  /// 每次「打开当前章」的请求代号：切章/换音色后旧请求的结果必须丢弃。
  int _playEpoch = 0;

  /// 进入页面时的定位只消费一次；之后切章、换音色都按自然起点播。
  double _startRatio = 0;
  int _startParagraph = 0;

  /// dispose 里不能再查 context：store 引用先缓存。
  late final ListenProgressStore _listening = AppScope.read(context).listening;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  /// 徽标文案：音色表还没拿到就不画（路径未知时不许编一个精度出来）。
  String get _badgeText {
    final tones = _tones;
    if (tones == null) return '';
    return speechBadgeOf(
      tones.hasRecordedAudio ? SpeechPath.recorded : SpeechPath.platformTone,
      SpeechGranularity.paragraph,
    );
  }

  @override
  void initState() {
    super.initState();
    final rec = AppScope.read(context).listening.entry(widget.bookId);
    _record = rec;
    if (rec != null) {
      _index = rec.chapterIndex.clamp(0, _maxIndex);
      _resumeMs = rec.positionMs;
    }
    _startRatio = widget.startRatio;
    _startParagraph = widget.startParagraph;
    WidgetsBinding.instance.addObserver(this);
    _errSub = _engine.stream.error.listen((e) {
      if (!mounted) return;
      setState(() => _playError = e.toString());
    });
    // 固定周期落盘：以前的写法是「每个位置事件重置 5s timer」，
    // 位置事件比 5s 密，等于永远不会保存，进程被杀就丢进度。
    _saveTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _saveProgress());
    _loadPrefs();
    // 位置事件驱动定时与预取：_posSub 此前只声明未订阅，这里补上接线。
    _posSub = _engine.stream.position.listen(_onPosition);
    _doneSub = _engine.stream.completed.listen((done) {
      if (!done) return;
      // 「本章播完停」：先让组件判决（fire 置连播抑制位），再**先消费抑制位**
      // 再决定连播（注意事项 2）；绝不改写 listen.autoNext 的持久化偏好（PRD）。
      if (_sleep.mode == SleepMode.endOfChapter) {
        final decision = _sleep.tick(
          position: _lastPos,
          chapterCompleted: true,
        );
        if (decision.stop) unawaited(_applySleepStop());
      }
      if (_sleep.consumeSleepSuppressAutoNext()) return;
      if (!_autoNext || _index >= _maxIndex) return;
      // 章间呼吸：与控制器同一份工具函数（同一默认档、同一取消语义）。
      final epoch = _playEpoch;
      unawaited(() async {
        final current = await awaitChapterGap(
          _listenSettings?.chapterGapMs ?? kDefaultChapterGapMs,
          isCurrent: () => epoch == _playEpoch && mounted,
        );
        if (!current || !mounted) return;
        if (_index >= _maxIndex) return;
        await _go(1);
      }());
    });
    _loadTones();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _sleepTick.dispose();
    _posSub?.cancel();
    _doneSub?.cancel();
    _errSub?.cancel();
    _saveProgress();
    // 页面即本页听书会话：离页等价于 close()，去重集一起失效（注意事项 5）。
    _prefetcher.invalidate();
    _publishStoppedMedia();
    _engine.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台/被系统回收前立即落盘，不等 5s 周期。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveProgress();
    }
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
    final epoch = ++_playEpoch;
    final chapter = widget.chapters[_index];
    setState(() {
      _loadingTrack = true;
      _error = null;
    });
    try {
      final track = await AppScope.read(context)
          .api
          .audioStream(widget.bookId, chapter.id, tone.id);
      if (!mounted || epoch != _playEpoch) return;
      setState(() {
        _track = track;
        _loadingTrack = false;
      });
      await _open(track, epoch: epoch);
      if (!mounted || epoch != _playEpoch) return;
      // 段落级对齐：用上游时间点把「读到的段落」换算成毫秒（比按时长等分准）。
      if (_startParagraph > 0 || _startRatio > 0) {
        try {
          final points = await AppScope.read(context)
              .api
              .audioTimepoints(widget.bookId, chapter.id, tone.id);
          if (!mounted || epoch != _playEpoch) return;
          await _waitDuration();
          if (!mounted || epoch != _playEpoch) return;
          final ms = points.offsetMs(
              paragraphIndex: _startParagraph, ratio: _startRatio);
          if (ms > 0) {
            await _engine.seek(Duration(milliseconds: ms));
          }
          // 进入定位只消费一次：切章/换音色不该再跳回同一比例。
          if (epoch == _playEpoch) {
            _startRatio = 0;
            _startParagraph = 0;
          }
        } catch (_) {
          // 时间点取不到就用比例定位。
        }
      }
    } catch (e) {
      if (!mounted || epoch != _playEpoch) return;
      setState(() {
        _error = e;
        _loadingTrack = false;
      });
    }
  }

  Future<void> _open(AudioStream track, {int epoch = 0}) async {
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
    if (!mounted || epoch != _playEpoch) return;
    await _engine.setRate(_speed);
    if (!mounted || epoch != _playEpoch) return;
    // 从阅读到的位置开始听（按章内比例换算成毫秒）。
    if (_startRatio > 0 && track.durationMs > 0) {
      await _waitDuration();
      if (!mounted || epoch != _playEpoch) return;
      final ms = (track.durationMs * _startRatio).round();
      await _engine.seek(Duration(milliseconds: ms));
    }
    if (_resumeMs > 0) {
      await _engine.seek(Duration(milliseconds: _resumeMs));
      _resumeMs = 0;
    }
    if (mounted && epoch == _playEpoch) {
      // 切章 position 归零 → 媒体时间轴基准重置：重新武装定时（注意事项 3）。
      final mode = _sleep.mode;
      if (mode != SleepMode.off) {
        _sleep.setMode(mode, minutes: _sleep.minutes);
      }
      setState(() => _playing = true);
    }
  }

  void _onPosition(Duration p) {
    _lastPos = p;
    _sleepTick.value = p.inSeconds;
    if (!_playing) return;
    if (_sleep.armed) {
      // 音轨路径没有句级时间点 → sentenceEndMs 恒 null → 到点立即停；
      // 「该音源只能整点停止」已在控制区注明（注意事项 4）。
      final decision = _sleep.tick(position: p, sentenceEndMs: null);
      if (decision.stop) {
        unawaited(_applySleepStop());
      }
    }
    _drivePrefetch(p);
    _publishMedia();
  }

  /// 系统媒体会话（Android）：与控制器共用同一座桥与同一套命令，
  /// 只是播放器换成本页自己的 `_engine`（两条并行路径的既有现状）。
  DateTime _lastMediaPublish = DateTime.fromMillisecondsSinceEpoch(0);

  void _publishMedia({bool force = false}) {
    final bridge = ListenMediaBridge.instance;
    if (bridge == null) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastMediaPublish) <
            const Duration(milliseconds: 200)) {
      return;
    }
    _lastMediaPublish = now;
    bridge.attach(_onMediaCommand);
    final chapter = _chapter;
    unawaited(
      bridge.publish(
        ListenMediaState(
          mediaId: chapter.id,
          title: widget.bookTitle,
          chapterTitle: chapter.title,
          artUri: widget.coverUrl.isEmpty ? null : widget.coverUrl,
          playing: _playing,
          buffering: _loadingTrack,
          position: _lastPos,
          // 音轨路径不给总时长：拿 0 冒充会让锁屏进度条一直是满的。
          total: null,
          speed: _speed,
          chapterIndex: _index,
          chapterCount: widget.chapters.length,
          canNext: _index < _maxIndex,
          canPrev: _index > 0,
        ),
      ),
    );
  }

  /// 离页等价于会话结束：推一个 idle 再解绑，不留“点击没人接”的假通知。
  void _publishStoppedMedia() {
    final bridge = ListenMediaBridge.instance;
    if (bridge == null) return;
    unawaited(
      bridge.publish(
        ListenMediaState(
          mediaId: widget.bookId.isEmpty ? 'idle' : widget.bookId,
          title: widget.bookTitle,
          chapterTitle: '',
          playing: false,
          finished: true,
          speed: _speed,
        ),
      ),
    );
    bridge.detach(_onMediaCommand);
  }

  void _onMediaCommand(ListenMediaCommand cmd, Duration? position) {
    switch (cmd) {
      case ListenMediaCommand.play:
        if (!_playing) unawaited(_toggle());
      case ListenMediaCommand.pause:
        if (_playing) unawaited(_toggle());
      case ListenMediaCommand.toggle:
        unawaited(_toggle());
      case ListenMediaCommand.nextChapter:
        unawaited(_go(1));
      case ListenMediaCommand.prevChapter:
        unawaited(_go(-1));
      case ListenMediaCommand.stop:
        // 本页没有 close()：停止键只暂停，不拆会话。
        if (_playing) unawaited(_toggle());
      case ListenMediaCommand.seekTo:
        if (position != null) unawaited(_engine.seek(position));
      case ListenMediaCommand.prevSentence:
      case ListenMediaCommand.nextSentence:
        // 音轨路径没有句级时间点：退化为前后 15s，比按章跳更接近“上一句”的预期。
        final step = Duration(
          seconds: cmd == ListenMediaCommand.prevSentence ? -15 : 15,
        );
        final target = _lastPos + step;
        unawaited(
          _engine.seek(target < Duration.zero ? Duration.zero : target),
        );
      case ListenMediaCommand.duck:
        unawaited(_engine.setVolume(0.25));
      case ListenMediaCommand.unduck:
        unawaited(_engine.setVolume(1.0));
    }
  }

  /// 到点先落进度再暂停（PRD 硬约束）；pause 保留会话，用户随时可继续。
  Future<void> _applySleepStop() async {
    await _saveProgress();
    try {
      await _engine.pause();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _playing = false);
    // fire 后组件落回 off：prefs 跟着写，下次进页不复活已用完的定时。
    await _persistSleep();
  }

  void _drivePrefetch(Duration p) {
    final settings = _listenSettings;
    if (settings == null || !settings.prefetchEnabled) return;
    final tone = _tone;
    if (tone == null) return;
    final nextIndex = _index + 1;
    if (nextIndex > _maxIndex) return;
    final next = widget.chapters[nextIndex];
    final total = Duration(milliseconds: _track?.durationMs ?? 0);
    if (!_prefetcher.shouldTrigger(
      taskId: next.id,
      position: p,
      total: total,
    )) {
      return;
    }
    // 现场捕获 api 与世代：work 迟到时按 isCurrent 丢弃，不碰 UI。
    final api = AppScope.read(context).api;
    final epoch = _playEpoch;
    unawaited(_prefetcher.pump(
      taskId: next.id,
      epoch: epoch,
      isCurrent: (value) => value == _playEpoch,
      work: () async {
        // 音轨版 work（design §4）：audioStream 让 core 提前落 audio_cache/，
        // 顺带拿时间点。403/无音轨等失败一律静默 —— 预取不许打扰当前播放。
        try {
          await api.audioStream(widget.bookId, next.id, tone.id);
          if (!mounted || epoch != _playEpoch) return;
          await api.audioTimepoints(widget.bookId, next.id, tone.id);
        } catch (_) {}
      },
    ));
  }

  /// 定时状态落盘：唯一入口 `ReaderListenSettings`（不另建 prefs 键）。
  Future<void> _persistSleep() async {
    final s = _listenSettings;
    if (s == null) return;
    try {
      await s.setSleepMode(_sleep.mode);
      final minutes = _sleep.minutes;
      if (minutes > 0) await s.setSleepMinutes(minutes);
    } catch (_) {}
  }

  /// 定时浮层入口：与阅读页同一个 sheet、同一个组件类，本页不复制逻辑。
  Future<void> _openSleepSheet() async {
    await showListenSleepSheet(
      context,
      timer: _sleep,
      refresh: _sleepTick,
      onSaved: () {
        unawaited(_persistSleep());
        if (mounted) setState(() {});
      },
    );
  }

  /// 定时状态文案：只换算 [SleepTimer.remaining]，本页不自建 Timer。
  String get _sleepLabel {
    final left = _sleep.remaining;
    if (_sleep.mode == SleepMode.endOfChapter) return '本章播完后停止';
    if (left == null) return '定时已设定，开播后开始计时';
    final s = left.inSeconds;
    return '剩余 ${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}（暂停不计时）';
  }

  Future<void> _toggle() async {
    if (_track == null) {
      await _playCurrent();
      return;
    }
    await _engine.playOrPause();
    if (mounted) setState(() => _playing = !_playing);
  }

  Future<void> _go(int delta) =>
      _selectChapter((_index + delta).clamp(0, _maxIndex));

  /// 切到指定章：清掉上一章的续播位置与「进入定位」，再播新章。
  Future<void> _selectChapter(int index) async {
    if (index == _index) return;
    await _saveProgress();
    if (!mounted) return;
    _resumeMs = 0;
    _startRatio = 0;
    _startParagraph = 0;
    setState(() => _index = index);
    await _playCurrent();
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bookTitle),
        // 精度徽标：这一页只播平台音轨（真人讲书 / 智能朗读），段级是**结构性**事实，
        // 徽标如实写「段」，不伪装成词级（design.md §6）。
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: SpeechBadge(text: _badgeText)),
          ),
        ],
      ),
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
                        onTap: () => _selectChapter(chapter.index),
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
                              // 换音色：音轨键全变，预取去重必须失效（design §3）。
                              _prefetcher.invalidate();
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
                IconButton(
                  tooltip: '定时关闭',
                  icon: Icon(
                    _sleep.armed
                        ? Icons.bedtime
                        : Icons.bedtime_outlined,
                    color: _sleep.armed ? theme.colorScheme.primary : null,
                  ),
                  onPressed: _openSleepSheet,
                ),
              ],
            ),
            // 定时状态只来自组件（remaining 换算在本页一处）；音轨无句级
            // 时间点，到点只能整停，必须如实说明（注意事项 4）。
            if (_sleep.armed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _sleepLabel,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            if (_sleep.armed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '该音源只能整点停止',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
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
      final listen = ReaderListenSettings(prefs);
      // 定时恢复只在未武装时进行（与控制器 _loadPrefs 同一规则）。
      if (_sleep.mode == SleepMode.off) {
        final saved = listen.sleepMode;
        if (saved != SleepMode.off) {
          _sleep.setMode(saved, minutes: listen.sleepMinutes);
        }
      }
      setState(() {
        // 按书语速优先，回落全局 —— 两条播放路径同一口径。
        _speed = (prefs.getDouble(
                      ReaderListenSettings.speedKeyOf(widget.bookId),
                    ) ??
                    prefs.getDouble(_speedKey) ??
                    1.0)
            .clamp(0.5, 2.0);
        _autoNext = prefs.getBool(_autoNextKey) ?? true;
        _listenSettings = listen;
      });
    } catch (_) {
      // 偏好读不到就用默认值。
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 与控制器同口径：按书键 + 全局键都写（全局是新书的默认值）。
      await prefs.setDouble(_speedKey, _speed);
      await prefs.setDouble(
        ReaderListenSettings.speedKeyOf(widget.bookId),
        _speed,
      );
      await prefs.setBool(_autoNextKey, _autoNext);
    } catch (_) {
      // 偏好写失败不影响播放。
    }
  }

  /// 写入听书进度（章节 + 章内位置）。
  Future<void> _saveProgress() async {
    if (!mounted) return;
    final pos = _engine.state.position;
    // 位置没变就不重复落盘：5s 周期 + 生命周期回调会重复触发。
    if (pos == _lastSavedPos) return;
    _lastSavedPos = pos;
    try {
      await _listening.record(
        bookId: widget.bookId,
        title: widget.bookTitle,
        coverUrl: widget.coverUrl,
        chapterId: _chapter.id,
        chapterTitle: _chapter.title,
        chapterIndex: _index,
        chapters: widget.chapters.length,
        toneId: _tone?.id ?? 0,
        positionMs: pos.inMilliseconds,
      );
    } catch (_) {
      // 进度写入失败不影响播放。
    }
  }

  /// 等播放器拿到时长再定位：open 刚发出时 seek 会被忽略。
  Future<void> _waitDuration() async {
    try {
      await _engine.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 超时就按当前状态定位。
    }
  }
  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
