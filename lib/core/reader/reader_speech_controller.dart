import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/audio.dart';
import '../../models/book.dart';
import '../../store/stores.dart';
import '../aqua_api.dart';
import '../player/player_engine.dart';

/// 全局听书控制器：阅读页内听书、独立听书页、离开页面后的继续播放共用同一实例。
///
/// 刻意不持有 `BuildContext`：依赖（api / 进度 store）在构造时注入，页面只订阅
/// 与渲染。这样控制器可以挂在 `AppScope` 上，比页面活得更久。
class ReaderSpeechController extends ChangeNotifier {
  ReaderSpeechController({
    required AquaApi api,
    required ListenProgressStore store,
    PlayerEngine? engine,
  }) : _engine = engine ?? MpvPlayerEngine() {
    _api = api;
    _store = store;
  }

  static const String speedKey = 'listen.speed';
  static const String autoNextKey = 'listen.autoNext';

  late final AquaApi _api;
  late final ListenProgressStore _store;
  final PlayerEngine _engine;

  String _bookId = '';
  String _bookTitle = '';
  String _coverUrl = '';
  List<BookChapter> _chapters = const <BookChapter>[];
  int _chapterIndex = 0;

  AudioTones? _tones;
  AudioTone? _tone;
  AudioTimepoints _points = const AudioTimepoints();

  bool _loading = false;
  bool _playing = false;
  Object? _error;
  Duration _position = Duration.zero;
  int _paragraphIndex = 0;
  int _paragraphCount = 0;
  double _speed = 1.0;
  bool _autoNext = true;

  /// 每次「打开某章」的代号：切章/换音色后旧请求的结果必须丢弃。
  int _epoch = 0;

  Timer? _saveTimer;
  Duration _lastSaved = Duration.zero;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  String get bookId => _bookId;
  String get bookTitle => _bookTitle;
  List<BookChapter> get chapters => _chapters;
  int get chapterIndex => _chapterIndex;
  AudioTones? get tones => _tones;
  AudioTone? get tone => _tone;
  bool get loading => _loading;
  bool get playing => _playing;
  Object? get error => _error;
  Duration get position => _position;
  int get paragraphIndex => _paragraphIndex;
  double get speed => _speed;
  bool get autoNext => _autoNext;

  /// 是否有正在进行的朗读会话（用于全局迷你条与页面接管判断）。
  bool get isActive => _bookId.isNotEmpty;

  BookChapter? get currentChapter =>
      _chapterIndex >= 0 && _chapterIndex < _chapters.length
          ? _chapters[_chapterIndex]
          : null;

  bool isFor(String bookId) => _bookId == bookId;

  /// 阅读页把「清洗后的段落数」告诉控制器：段落下标只能由这个数字收敛。
  void setParagraphCount(int count) {
    if (count == _paragraphCount) return;
    _paragraphCount = count;
    _recomputeParagraph();
  }

  /// 打开一本书并从指定位置开始朗读。
  Future<void> start({
    required String bookId,
    required String bookTitle,
    required String coverUrl,
    required List<BookChapter> chapters,
    required int chapterIndex,
    int startParagraph = 0,
    double startRatio = 0,
    int toneId = 0,
  }) async {
    final sameSession = _bookId == bookId && _playing;
    _bookId = bookId;
    _bookTitle = bookTitle;
    _coverUrl = coverUrl;
    _chapters = chapters;
    await _loadPrefs();
    if (sameSession) {
      notify();
      return;
    }
    _ensureSubs();
    if (_tones == null) {
      try {
        _tones = await _api.audioTones(bookId);
      } catch (e) {
        _error = e;
        notify();
        return;
      }
      final saved = toneId > 0 ? toneId : (_store.entry(bookId)?.toneId ?? 0);
      final matched = _tones!.tones.where((t) => t.id == saved).toList();
      _tone = matched.isNotEmpty
          ? matched.first
          : (_tones!.tones.isEmpty ? null : _tones!.tones.first);
      if (_tone == null) {
        _error = '这本书暂时没有可用的朗读音色';
        notify();
        return;
      }
    }
    await _openChapter(chapterIndex, startParagraph: startParagraph, startRatio: startRatio);
  }

  Future<void> toggle() async {
    if (!isActive) return;
    if (_loading) return;
    await _engine.playOrPause();
    _playing = !_playing;
    notify();
    if (!_playing) unawaited(_saveProgress());
  }

  Future<void> next() async {
    if (_chapterIndex >= _chapters.length - 1) return;
    await _saveProgress();
    await _openChapter(_chapterIndex + 1);
  }

  Future<void> previous() async {
    if (_chapterIndex <= 0) return;
    await _saveProgress();
    await _openChapter(_chapterIndex - 1);
  }

  Future<void> setTone(AudioTone tone) async {
    if (_tone?.id == tone.id) return;
    _tone = tone;
    await _saveProgress();
    await _openChapter(_chapterIndex, keepPosition: true);
  }

  /// 按音色 id 切换（UI 传的是 id）。
  Future<void> setToneById(int toneId) async {
    final tones = _tones?.tones ?? const <AudioTone>[];
    for (final tone in tones) {
      if (tone.id == toneId) {
        await setTone(tone);
        return;
      }
    }
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.5, 3.0);
    try {
      await _engine.setRate(_speed);
    } catch (_) {}
    notify();
    unawaited(_savePrefs());
  }

  Future<void> setAutoNext(bool value) async {
    _autoNext = value;
    notify();
    unawaited(_savePrefs());
  }

  /// 跳到上一段 / 下一段（朗读中）。
  Future<void> stepParagraph(int delta) async {
    if (_paragraphCount <= 0) return;
    final target = (_paragraphIndex + delta).clamp(0, _paragraphCount - 1);
    if (target == _paragraphIndex) return;
    final ms = _points.startMsOfParagraph(target,
        paragraphCount: _paragraphCount);
    if (ms <= 0) return;
    await _engine.seek(Duration(milliseconds: ms));
    _paragraphIndex = target;
    notify();
  }

  /// 停止朗读并清空会话（页面关闭入口调用）。控制器本身留活，供下次复用。
  Future<void> close() async {
    _epoch++;
    _saveTimer?.cancel();
    _saveTimer = null;
    unawaited(_saveProgress());
    try {
      await _engine.stop();
    } catch (_) {}
    _bookId = '';
    _bookTitle = '';
    _coverUrl = '';
    _chapters = const <BookChapter>[];
    _chapterIndex = 0;
    _tones = null;
    _tone = null;
    _points = const AudioTimepoints();
    _playing = false;
    _loading = false;
    _error = null;
    _position = Duration.zero;
    _paragraphIndex = 0;
    _paragraphCount = 0;
    notify();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    unawaited(_engine.dispose());
    super.dispose();
  }

  // ---------- 内部 ----------

  void notify() => notifyListeners();

  void _ensureSubs() {
    if (_subs.isNotEmpty) return;
    _subs.add(_engine.stream.position.listen(_onPosition));
    _subs.add(_engine.stream.playing.listen((playing) {
      if (_playing == playing) return;
      _playing = playing;
      notify();
    }));
    _subs.add(_engine.stream.completed.listen((done) {
      if (!done || !_autoNext) return;
      if (_chapterIndex >= _chapters.length - 1) return;
      unawaited(next());
    }));
    _subs.add(_engine.stream.error.listen((message) {
      if (message.isEmpty) return;
      _error = message;
      _playing = false;
      notify();
    }));
  }

  void _onPosition(Duration p) {
    _position = p;
    _recomputeParagraph();
    // mpv 位置事件很密：节流 250ms，避免阅读页整页重建。
    final now = DateTime.now();
    if (now.difference(_lastNotify) < const Duration(milliseconds: 250)) return;
    _lastNotify = now;
    notify();
  }

  void _recomputeParagraph() {
    if (_paragraphCount <= 0) return;
    final next = _points.paragraphAt(
      _position.inMilliseconds,
      paragraphCount: _paragraphCount,
    );
    if (next != _paragraphIndex) _paragraphIndex = next;
  }

  Future<void> _openChapter(
    int index, {
    int startParagraph = 0,
    double startRatio = 0,
    bool keepPosition = false,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    final tone = _tone;
    if (tone == null) return;
    final epoch = ++_epoch;
    _chapterIndex = index;
    _loading = true;
    _error = null;
    notify();
    final chapter = _chapters[index];
    final resumeMs = keepPosition ? _position.inMilliseconds : 0;
    try {
      final track =
          await _api.audioStream(_bookId, chapter.id, tone.id);
      if (epoch != _epoch) return;
      // 时间点与音轨并行：高亮依赖段落映射，早点拿到。
      unawaited(_loadTimepoints(chapter.id, tone.id, epoch));
      await _engine.initialize();
      if (epoch != _epoch) return;
      final lavf = [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (track.keyHex.isNotEmpty) 'decryption_key=${track.keyHex}',
      ].join(',');
      await _engine.setProperty('demuxer-lavf-o', lavf);
      try {
        await _engine.setProperty(
          'http-header-fields',
          'User-Agent: com.dragon.read,Referer: https://reading.snssdk.com/',
        );
      } catch (_) {}
      await _engine.open(Media(track.path), play: true);
      if (epoch != _epoch) return;
      await _engine.setRate(_speed);
      if (epoch != _epoch) return;
      _playing = true;
      _loading = false;
      _position = Duration.zero;
      _paragraphIndex = 0;
      _startSaveTimer();

      final targetMs = resumeMs > 0
          ? resumeMs
          : (startParagraph > 0 || startRatio > 0)
              ? null
              : (_store.entry(_bookId)?.positionMs ?? 0);
      if (targetMs != null && targetMs > 0) {
        await _engine.seek(Duration(milliseconds: targetMs));
      } else if (startParagraph > 0 || startRatio > 0) {
        await _waitDuration();
        if (epoch != _epoch) return;
        final points = await _api.audioTimepoints(_bookId, chapter.id, tone.id);
        if (epoch != _epoch) return;
        _points = points;
        final ms = points.offsetMs(
            paragraphIndex: startParagraph, ratio: startRatio);
        if (ms > 0) await _engine.seek(Duration(milliseconds: ms));
      }
      notify();
    } catch (e) {
      if (epoch != _epoch) return;
      _error = e;
      _loading = false;
      _playing = false;
      notify();
    }
  }

  Future<void> _loadTimepoints(String chapterId, int toneId, int epoch) async {
    try {
      final points = await _api.audioTimepoints(_bookId, chapterId, toneId);
      if (epoch != _epoch) return;
      _points = points;
      _recomputeParagraph();
      notify();
    } catch (_) {
      // 时间点拿不到就退化成不精确高亮（仍按段落数比例估算）。
      _points = const AudioTimepoints();
    }
  }

  Future<void> _waitDuration() async {
    try {
      await _engine.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_saveProgress()));
  }

  Future<void> _saveProgress() async {
    if (_bookId.isEmpty) return;
    final chapter = currentChapter;
    if (chapter == null) return;
    final pos = _position;
    if (pos == _lastSaved) return;
    _lastSaved = pos;
    try {
      await _store.record(
        bookId: _bookId,
        title: _bookTitle,
        coverUrl: _coverUrl,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        chapterIndex: _chapterIndex,
        chapters: _chapters.length,
        toneId: _tone?.id ?? 0,
        positionMs: pos.inMilliseconds,
      );
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _speed = (prefs.getDouble(speedKey) ?? _speed).clamp(0.5, 3.0);
      _autoNext = prefs.getBool(autoNextKey) ?? _autoNext;
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(speedKey, _speed);
      await prefs.setBool(autoNextKey, _autoNext);
    } catch (_) {}
  }
}
