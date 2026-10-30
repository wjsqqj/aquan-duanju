import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/audio.dart';
import '../../models/book.dart';
import '../../store/stores.dart';
import '../aqua_api.dart';
import '../book_text.dart';
import '../player/player_engine.dart';
import '../tts/edge/edge_constants.dart';
import '../tts/edge/edge_engine.dart';
import '../tts/speech_engine.dart';
import '../tts/tts_cache.dart';
import '../tts/tts_composer.dart';
import '../tts/tts_models.dart';
import 'speech/speech_unit.dart';

/// 端点漂移时如何重建引擎：返回替换用的引擎，`null` 表示没有下一个端点（直接报错）。
///
/// 抽成注入点有两个理由：① 换端点是**显式**动作，不能让协议漂移变成看不见的行为
/// （design.md §5 修正 2）；② 单测必须能断言降级路径而绝不真的联网。
typedef TtsEngineFallback = SpeechEngine? Function(
  SpeechEngine current,
  String proxy,
);

/// 默认降级：换一个 Edge preset 重建引擎（`EdgeSpeechEngine` 自己不在单次请求里
/// 静默换 host，见 `edge_engine.dart` 的 [EdgeSpeechEngine.fallbackPreset]）。
SpeechEngine? _edgePresetFallback(SpeechEngine current, String proxy) {
  if (current is! EdgeSpeechEngine) return null;
  final next = current.fallbackPreset;
  if (next == null) return null;
  return EdgeSpeechEngine(preset: next, proxy: proxy);
}

/// TTS 路径的 mpv 参数：拼接出来的 mp3 不需要 `decryption_key`，但白名单与音轨路径
/// 保持一致（design.md §6）。
const String _kTtsDemuxerOptions =
    'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]';

/// 全局听书控制器：阅读页内听书、独立听书页、离开页面后的继续播放共用同一实例。
///
/// 刻意不持有 `BuildContext`：依赖（api / 进度 store）在构造时注入，页面只订阅
/// 与渲染。这样控制器可以挂在 `AppScope` 上，比页面活得更久。
class ReaderSpeechController extends ChangeNotifier {
  /// 合成引擎与缓存**默认由控制器自己懒建**：`main.dart` / `AppScope` 不需要知道
  /// TTS 的存在（design.md §9）。测试注入假引擎与临时目录缓存。
  ReaderSpeechController({
    required AquaApi api,
    required ListenProgressStore store,
    PlayerEngine? engine,
    this._ttsEngine,
    this._ttsCache,
    TtsComposer? ttsComposer,
    TtsEngineFallback? ttsEngineFallback,
  }) : _engine = engine ?? MpvPlayerEngine(),
       _ttsComposer = ttsComposer ?? TtsComposer(),
       _ttsEngineFallback = ttsEngineFallback ?? _edgePresetFallback {
    _api = api;
    _store = store;
  }

  static const String speedKey = 'listen.speed';
  static const String autoNextKey = 'listen.autoNext';

  /// 回滚开关：关掉后「无平台音色」回到今日行为（只报错不合成）。
  static const String ttsEnabledKey = 'listen.tts.enabled';
  static const String ttsVoiceKey = 'listen.tts.voice';
  static const String ttsProxyKey = 'listen.tts.proxy';
  static const String ttsQuotaKey = 'listen.tts.quotaMb';

  late final AquaApi _api;
  late final ListenProgressStore _store;
  final PlayerEngine _engine;

  /// 合成引擎（懒建）；403 降级时会被替换成另一个 preset 的实例。
  SpeechEngine? _ttsEngine;
  TtsCache? _ttsCache;
  final TtsComposer _ttsComposer;
  final TtsEngineFallback _ttsEngineFallback;

  String _bookId = '';
  String _bookTitle = '';
  String _coverUrl = '';
  List<BookChapter> _chapters = const <BookChapter>[];
  int _chapterIndex = 0;

  AudioTones? _tones;
  AudioTone? _tone;

  /// 时间点真值源：音轨路径 = [ParagraphTimelineAdapter]（委托既有 [AudioTimepoints]，
  /// 逐项行为不变），TTS 路径 = [SpeechTimeline]。高亮与跳段只认这一个抽象。
  SpeechPositions _positions = const ParagraphTimelineAdapter(
    AudioTimepoints(),
  );

  bool _loading = false;
  bool _playing = false;
  Object? _error;
  Duration _position = Duration.zero;
  int _paragraphIndex = 0;
  int _paragraphCount = 0;
  double _speed = 1.0;
  bool _autoNext = true;

  /// 本次会话走不走本地合成：无平台音色且 `listen.tts.enabled` 为真时才置位。
  /// 切章、上下章、自动连播都按它回到 [_startTts]，音轨链路的行为则完全照旧。
  bool _useTts = false;

  // TTS 侧的设置快照（`_loadPrefs` 里读一次，构造引擎与缓存时用）。
  bool _ttsEnabled = true;
  String _ttsVoiceId = '';
  String _ttsProxy = '';
  int _ttsQuotaMb = TtsCacheLimits.defaultQuotaMb;

  /// 每次「打开某章」的代号：切章/换音色后旧请求的结果必须丢弃。
  int _epoch = 0;

  Timer? _saveTimer;
  Duration _lastSaved = Duration.zero;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

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

  /// 当前该高亮的那个字；精度不足时是 `null`（音轨链路、句级引擎都给不出）。
  /// 只暴露数据，高亮 UI 属于下一个任务。
  SpeechPoint? get currentWord => _positions.wordAt(_position.inMilliseconds);

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
    }
    if (_tone == null) {
      // 以前这里直接报错收工。现在默认改走本地合成：绝大多数书根本没有平台音轨，
      // 「没有可用的朗读音色」对用户来说等同于「听书坏了」。开关关掉即回到今日行为。
      if (!_ttsEnabled) {
        _useTts = false;
        _error = '这本书暂时没有可用的朗读音色';
        notify();
        return;
      }
      _useTts = true;
      await _startTts(
        chapterIndex,
        startParagraph: startParagraph,
        startRatio: startRatio,
      );
      return;
    }
    _useTts = false;
    await _openChapter(
      chapterIndex,
      startParagraph: startParagraph,
      startRatio: startRatio,
    );
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
    // 用户明确选了一个平台音色，这条会话就交回音轨链路；`_openChapter` 里
    // 的世代号会让进行中的合成结果作废。
    _useTts = false;
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
    final ms = _positions.startMsOfParagraph(
      target,
      paragraphCount: _paragraphCount,
    );
    if (ms <= 0) return;
    await _engine.seek(Duration(milliseconds: ms));
    _paragraphIndex = target;
    notify();
  }

  /// 停止朗读并清空会话（页面关闭入口调用）。控制器本身留活，供下次复用。
  Future<void> close() async {
    // 世代号 +1 就是中止信号：编排层每个 await 之后都问一次 `isCurrent`，
    // 进行中的合成会在下一段边界抛 `cancelled` 自行退出（不留半成品）。
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
    _positions = const ParagraphTimelineAdapter(AudioTimepoints());
    _playing = false;
    _loading = false;
    _error = null;
    _position = Duration.zero;
    _paragraphIndex = 0;
    _paragraphCount = 0;
    _useTts = false;
    notify();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final tts = _ttsEngine;
    if (tts != null) unawaited(tts.dispose());
    unawaited(_engine.dispose());
    super.dispose();
  }

  // ---------- 内部 ----------

  void notify() => notifyListeners();

  void _ensureSubs() {
    if (_subs.isNotEmpty) return;
    _subs.add(_engine.stream.position.listen(_onPosition));
    _subs.add(
      _engine.stream.playing.listen((playing) {
        if (_playing == playing) return;
        _playing = playing;
        notify();
      }),
    );
    _subs.add(
      _engine.stream.completed.listen((done) {
        if (!done || !_autoNext) return;
        if (_chapterIndex >= _chapters.length - 1) return;
        unawaited(next());
      }),
    );
    _subs.add(
      _engine.stream.error.listen((message) {
        if (message.isEmpty) return;
        _error = message;
        _playing = false;
        notify();
      }),
    );
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
    final next = _positions.paragraphAt(
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
    // 上下章与自动连播共用一个入口：TTS 会话换章必须继续走合成，否则第二章起
    // 会退回「没有可用音色」的老错误。
    if (_useTts) {
      await _startTts(
        index,
        startParagraph: startParagraph,
        startRatio: startRatio,
        keepPosition: keepPosition,
      );
      return;
    }
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
      final track = await _api.audioStream(_bookId, chapter.id, tone.id);
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
        _positions = ParagraphTimelineAdapter(points);
        final ms = points.offsetMs(
          paragraphIndex: startParagraph,
          ratio: startRatio,
        );
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
      _positions = ParagraphTimelineAdapter(points);
      _recomputeParagraph();
      notify();
    } catch (_) {
      // 时间点拿不到就退化成不精确高亮（仍按段落数比例估算）。
      _positions = const ParagraphTimelineAdapter(AudioTimepoints());
    }
  }

  Future<void> _waitDuration() async {
    try {
      await _engine.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// 本地合成链路：正文 → 朗读单元 → 查缓存（命中零网络）→ 合成 → 成对落盘 →
  /// 播放本地 mp3。高亮/跳段与音轨路径共用 [_onPosition]/[_recomputeParagraph]，
  /// 只是把真值源换成 [SpeechTimeline]。
  Future<void> _startTts(
    int index, {
    int startParagraph = 0,
    double startRatio = 0,
    bool keepPosition = false,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    final chapter = _chapters[index];
    final epoch = ++_epoch;
    _chapterIndex = index;
    _loading = true;
    _error = null;
    notify();
    final resumeMs = keepPosition ? _position.inMilliseconds : 0;
    try {
      final paragraphs = await _speechParagraphs(chapter);
      if (epoch != _epoch) return;
      final units = splitSpeechUnits(paragraphs);
      if (units.isEmpty) {
        throw const TtsException(
          TtsErrorCode.emptyAudio,
          message: '本章没有可朗读的正文',
        );
      }
      final product = await _produceChapterAudio(
        chapter: chapter,
        paragraphs: paragraphs,
        units: units,
        epoch: epoch,
      );
      if (epoch != _epoch) return;
      // 状态只在新章真正开播这一刻切换：段数与时间点必须同源，否则
      // `paragraphAt` 会把上一章的毫秒数落到下一章的段落上。
      _positions = product.timeline;
      _paragraphCount = paragraphs.length;
      await _engine.initialize();
      if (epoch != _epoch) return;
      await _engine.setProperty('demuxer-lavf-o', _kTtsDemuxerOptions);
      await _engine.open(Media(product.audioPath), play: true);
      if (epoch != _epoch) return;
      // 倍速只交给播放器：时间点存的是媒体时间轴，改语速绝不重新合成。
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
          ? _startMsOf(product.timeline, startParagraph, startRatio)
          : (_store.entry(_bookId)?.positionMs ?? 0);
      if (targetMs > 0) {
        await _engine.seek(Duration(milliseconds: targetMs));
      }
      if (epoch != _epoch) return;
      notify();
    } on TtsException catch (e) {
      // `cancelled` 只是「这一代已经被切章/关闭作废」，新任务正在跑，不该报错。
      if (epoch != _epoch || e.code == TtsErrorCode.cancelled) return;
      _error = e.friendlyText;
      _loading = false;
      _playing = false;
      notify();
    } catch (e) {
      if (epoch != _epoch) return;
      _error = e;
      _loading = false;
      _playing = false;
      notify();
    }
  }

  /// 取正文并清洗成段落。**必须与阅读页同一个入口**（`chapterText` +
  /// `htmlToParagraphs` + 去章标题）：朗读文本一旦和阅读文本不同，字符坐标就串位。
  Future<List<String>> _speechParagraphs(BookChapter chapter) async {
    final paragraphs = htmlToParagraphs(await _api.chapterText(chapter.id));
    // 正文里常带一行章节标题：顶栏已经显示过，朗读也不该先念一遍。
    if (paragraphs.isNotEmpty && paragraphs.first == chapter.title) {
      paragraphs.removeAt(0);
    }
    return paragraphs;
  }

  /// 拿这一章的音频产物：命中缓存则一次网络都不发；未命中才合成并成对落盘。
  Future<_TtsProduct> _produceChapterAudio({
    required BookChapter chapter,
    required List<String> paragraphs,
    required List<SpeechUnit> units,
    required int epoch,
  }) async {
    final engine = _tts;
    final cache = _cache;
    final voice = TtsVoice(
      id: _ttsVoiceId.isEmpty ? kEdgeFallbackVoice : _ttsVoiceId,
    );
    final key = TtsCacheKey(
      bookId: _bookId,
      chapterId: chapter.id,
      engineId: engine.id,
      // 音色进键（缓存键里没有倍速）：换音色必须重合成，改倍速不用。
      voiceId: voice.id,
    );
    final signature = cache.signatureOf(paragraphs);
    final hit = await cache.lookup(key, textSignature: signature);
    if (hit != null) {
      return _TtsProduct(hit.audioPath, hit.timeline);
    }
    final composition = await _composeWithFallback(
      paragraphs: paragraphs,
      units: units,
      voice: voice,
      epoch: epoch,
    );
    if (epoch != _epoch) {
      throw TtsException(
        TtsErrorCode.cancelled,
        message: '合成结束时 requestIndex=$epoch 已过期',
      );
    }
    await cache.save(
      key,
      audio: composition.audio,
      timeline: composition.timeline,
      textSignature: signature,
    );
    if (epoch != _epoch) {
      throw TtsException(
        TtsErrorCode.cancelled,
        message: '落盘结束时 requestIndex=$epoch 已过期',
      );
    }
    // 落盘后向缓存要路径：键的构成与有效性判定只有它知道，控制器不复制一份
    // 命名规则（重复一份就会和「成对删除」的语义打架）。
    final saved = await cache.lookup(key, textSignature: signature);
    if (saved == null) {
      throw const TtsException(
        TtsErrorCode.invalidCache,
        message: '合成产物落盘后校验未通过',
      );
    }
    return _TtsProduct(saved.audioPath, saved.timeline);
  }

  /// 合成整章；建连失败或 403（纠偏已无效）时换一个 preset **整章重试一次**。
  /// 重试只有一次：第二次失败直接抛，交给友好文案，不让端点漂移变成循环。
  Future<TtsComposition> _composeWithFallback({
    required List<String> paragraphs,
    required List<SpeechUnit> units,
    required TtsVoice voice,
    required int epoch,
  }) async {
    try {
      return await _composeOnce(
        paragraphs: paragraphs,
        units: units,
        voice: voice,
        epoch: epoch,
      );
    } on TtsException catch (e) {
      if (e.code == TtsErrorCode.cancelled || !_isEndpointDrift(e)) rethrow;
      final current = _tts;
      final next = _ttsEngineFallback(current, _ttsProxy);
      if (next == null) rethrow;
      _ttsEngine = next;
      await current.dispose();
      // `dispose()` 也是一个 await：期间用户可能已切章/切音色。旧代的降级结果
      // 必须在此作废，否则会白跑一整章的合成。
      if (epoch != _epoch) {
        throw const TtsException(TtsErrorCode.cancelled, message: '降级重试前请求已过期');
      }
      return _composeOnce(
        paragraphs: paragraphs,
        units: units,
        voice: voice,
        epoch: epoch,
      );
    }
  }

  Future<TtsComposition> _composeOnce({
    required List<String> paragraphs,
    required List<SpeechUnit> units,
    required TtsVoice voice,
    required int epoch,
  }) => _ttsComposer.composeChapter(
    engine: _tts,
    paragraphs: paragraphs,
    voice: voice,
    epoch: epoch,
    units: units,
    // 取消语义交给编排层：它在每个 await 之后都判一次世代，切章即中止。
    isCurrent: (value) => value == _epoch,
  );

  /// 只有「端点/凭据被拒」和「连不上」值得换端点；限流与内容问题重试也没用。
  static bool _isEndpointDrift(TtsException e) =>
      e.code == TtsErrorCode.authRejected || e.code == TtsErrorCode.transport;

  /// 朗读起点：段落对得上就按段内比例细分，对不上退回段起点。
  int _startMsOf(SpeechPositions positions, int paragraphIndex, double ratio) {
    final table = positions is SpeechTimeline ? positions : null;
    if (table != null) {
      for (final p in table.paragraphs) {
        if (p.paragraphIndex != paragraphIndex) continue;
        return (p.startMs + (p.endMs - p.startMs) * ratio.clamp(0.0, 1.0))
            .round();
      }
    }
    return positions.startMsOfParagraph(
      paragraphIndex,
      paragraphCount: _paragraphCount,
    );
  }

  /// 懒建合成引擎：`main.dart` 不注入任何东西，测试用构造参数换掉它。
  SpeechEngine get _tts => _ttsEngine ??= EdgeSpeechEngine(proxy: _ttsProxy);

  TtsCache get _cache => _ttsCache ??= TtsCache(quotaMb: _ttsQuotaMb);

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_saveProgress()),
    );
  }

  /// 听书进度只写 [ListenProgressStore]：与阅读进度两份文件互不覆盖
  /// （reader-paging-contract.md §9.4）。TTS 与音轨两条链路的 `positionMs`
  /// 同为媒体时间轴，可以互用。
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
      // 缺键按默认值：`listen.tts.enabled` 只有显式关掉才回滚（design.md §8）。
      _ttsEnabled = prefs.getBool(ttsEnabledKey) ?? true;
      _ttsVoiceId = prefs.getString(ttsVoiceKey) ?? '';
      _ttsProxy = prefs.getString(ttsProxyKey) ?? '';
      _ttsQuotaMb = prefs.getInt(ttsQuotaKey) ?? _ttsQuotaMb;
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

/// 一章的合成产物：可播放的本地文件 + 它对应的时间点表。
class _TtsProduct {
  const _TtsProduct(this.audioPath, this.timeline);

  final String audioPath;
  final SpeechTimeline timeline;
}
