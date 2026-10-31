/// 听书时间点与 TTS 引擎的数据模型。
///
/// 设计约束（`.trellis/tasks/10-30-listen-book-absorption/prd.md` 跨子任务约束）：
/// 1. 时间一律存**媒体时间轴**（毫秒），与倍速无关 —— 倍速由播放器 `setRate` 实现；
/// 2. 精度位（[SpeechGranularity]）必须由引擎真实声明，**禁止静默降级**：
///    拿不到词级时 [SpeechTimeline.wordAt] 返回 `null`，由上层决定显示什么；
/// 3. 字符坐标沿用阅读页的章内字符位（段落以 `'\n'` 相接），可直接与分页行区间求交集。
library;

import '../../models/audio.dart';
import '../reader/speech/speech_unit.dart';

/// 时间点表的精度档位。数值越大越精细。
enum SpeechGranularity {
  paragraph,
  sentence,
  word;

  static SpeechGranularity parse(String? name) {
    for (final g in SpeechGranularity.values) {
      if (g.name == name) return g;
    }
    return SpeechGranularity.paragraph;
  }
}

/// 一个可定位的语音片段：既有音频时间，也有章内字符位置。
class SpeechPoint {
  const SpeechPoint({
    required this.startMs,
    required this.endMs,
    required this.charStart,
    required this.charEnd,
    required this.unitIndex,
    this.text = '',
  });

  final int startMs;
  final int endMs;

  /// 章内字符偏移（含起不含止）。
  final int charStart;
  final int charEnd;

  /// 所属 speak unit 序号，用于回溯句子与段落。
  final int unitIndex;

  /// 该片段念的是什么（词级时为引擎返回的 token）。
  final String text;

  int get durationMs => (endMs - startMs).clamp(0, 1 << 31);

  /// 把一个多字符 token 按字符数**均分时长**，得到近似字级点。
  ///
  /// Edge/Azure 的中文 `WordBoundary` 给的是分词后的 token（1–3 字），不是逐字；
  /// 均分后误差在数十毫秒量级，卡拉OK 观感可用。调用方只在词级路径展开一次。
  List<SpeechPoint> expandPerChar() {
    final chars = charEnd - charStart;
    if (chars <= 1) {
      return <SpeechPoint>[this];
    }
    final per = durationMs / chars;
    // 逐字点各自保留那个字（`text` 与字符数一致时），否则上层取字面只能拿到空串。
    final perCharText = text.length == chars;
    final out = <SpeechPoint>[];
    for (var i = 0; i < chars; i++) {
      out.add(
        SpeechPoint(
          startMs: (startMs + per * i).round(),
          endMs: i == chars - 1 ? endMs : (startMs + per * (i + 1)).round(),
          charStart: charStart + i,
          charEnd: charStart + i + 1,
          unitIndex: unitIndex,
          text: perCharText ? text[i] : '',
        ),
      );
    }
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    's': startMs,
    'e': endMs,
    'cs': charStart,
    'ce': charEnd,
    'u': unitIndex,
    if (text.isNotEmpty) 't': text,
  };

  factory SpeechPoint.fromJson(Map<String, dynamic> json) => SpeechPoint(
    startMs: (json['s'] as num?)?.toInt() ?? 0,
    endMs: (json['e'] as num?)?.toInt() ?? 0,
    charStart: (json['cs'] as num?)?.toInt() ?? 0,
    charEnd: (json['ce'] as num?)?.toInt() ?? 0,
    unitIndex: (json['u'] as num?)?.toInt() ?? 0,
    text: json['t'] as String? ?? '',
  );
}

/// 段落级时间（由词/句点聚合得到）。
class ParagraphTiming {
  const ParagraphTiming({
    required this.paragraphIndex,
    required this.charStart,
    required this.charEnd,
    required this.startMs,
    required this.endMs,
  });

  final int paragraphIndex;
  final int charStart;
  final int charEnd;
  final int startMs;
  final int endMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': paragraphIndex,
    'cs': charStart,
    'ce': charEnd,
    's': startMs,
    'e': endMs,
  };

  factory ParagraphTiming.fromJson(Map<String, dynamic> json) =>
      ParagraphTiming(
        paragraphIndex: (json['p'] as num?)?.toInt() ?? 0,
        charStart: (json['cs'] as num?)?.toInt() ?? 0,
        charEnd: (json['ce'] as num?)?.toInt() ?? 0,
        startMs: (json['s'] as num?)?.toInt() ?? 0,
        endMs: (json['e'] as num?)?.toInt() ?? 0,
      );
}

/// 时间 ↔ 文本位置的查询接口：音轨路径与 TTS 路径都实现它，消费端只认一个抽象。
abstract class SpeechPositions {
  SpeechGranularity get granularity;

  /// 词级点；精度不足时返回 `null`（不降级、不猜）。
  SpeechPoint? wordAt(int ms);

  /// 句级点；精度不足时返回 `null`。
  SpeechPoint? sentenceAt(int ms);

  /// 当前毫秒落在哪个段落（结果 clamp 到 [paragraphCount]）。
  int paragraphAt(int ms, {required int paragraphCount});

  /// 跳到某段应该 seek 到多少毫秒。
  int startMsOfParagraph(int paragraphIndex, {required int paragraphCount});
}

/// 一章的时间点表。词/句/段三张表在构建时一次算好，查询只做二分 —— 渲染帧内
/// 不做派生计算，这是「高亮不卡顿」的前提。
class SpeechTimeline implements SpeechPositions {
  const SpeechTimeline({
    required this.granularity,
    required this.audioMs,
    this.words = const <SpeechPoint>[],
    this.sentences = const <SpeechPoint>[],
    this.paragraphs = const <ParagraphTiming>[],
  });

  @override
  final SpeechGranularity granularity;

  /// 整章音频时长（毫秒），来自字节数换算，不信任引擎自报之和。
  final int audioMs;
  final List<SpeechPoint> words;
  final List<SpeechPoint> sentences;
  final List<ParagraphTiming> paragraphs;

  bool get isEmpty => words.isEmpty && sentences.isEmpty && paragraphs.isEmpty;

  bool get hasWordLevel =>
      granularity == SpeechGranularity.word && words.isNotEmpty;

  @override
  SpeechPoint? wordAt(int ms) => hasWordLevel ? _lastNotAfter(words, ms) : null;

  @override
  SpeechPoint? sentenceAt(int ms) => sentences.isEmpty
      ? null
      : (granularity.index >= SpeechGranularity.sentence.index
            ? _lastNotAfter(sentences, ms)
            : null);

  @override
  int paragraphAt(int ms, {required int paragraphCount}) {
    if (paragraphCount <= 0) return 0;
    if (paragraphs.isEmpty) return 0;
    final idx = _lastIndexNotAfter(
      paragraphs.map((p) => p.startMs).toList(growable: false),
      ms,
    );
    if (idx < 0) {
      return paragraphs.first.paragraphIndex.clamp(0, paragraphCount - 1);
    }
    return paragraphs[idx].paragraphIndex.clamp(0, paragraphCount - 1);
  }

  @override
  int startMsOfParagraph(int paragraphIndex, {required int paragraphCount}) {
    if (paragraphs.isEmpty) return 0;
    for (final p in paragraphs) {
      if (p.paragraphIndex == paragraphIndex) return p.startMs;
    }
    // 没有该段的精确点：在相邻已知段之间按段落序号线性插值。
    // 直接「按比例落到时间点下标」会把后面段落的起点当成前面段落的（已知的坑）。
    ParagraphTiming? prev;
    ParagraphTiming? next;
    for (final p in paragraphs) {
      if (p.paragraphIndex < paragraphIndex) {
        prev = p;
      } else if (p.paragraphIndex > paragraphIndex) {
        next = p;
        break;
      }
    }
    if (prev == null) return 0; // 目标段在已知段之前
    if (next == null) return prev.endMs; // 目标段在已知段之后
    final span = next.paragraphIndex - prev.paragraphIndex;
    if (span <= 0) return next.startMs;
    final ratio = (paragraphIndex - prev.paragraphIndex) / span;
    return (prev.startMs + (next.startMs - prev.startMs) * ratio).round();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'granularity': granularity.name,
    'audio_ms': audioMs,
    'words': words.map((w) => w.toJson()).toList(),
    'sentences': sentences.map((w) => w.toJson()).toList(),
    'paragraphs': paragraphs.map((p) => p.toJson()).toList(),
  };

  factory SpeechTimeline.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) build) {
      final raw = json[key];
      if (raw is! List) return const <Never>[];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(build)
          .toList(growable: false);
    }

    return SpeechTimeline(
      granularity: SpeechGranularity.parse(json['granularity'] as String?),
      audioMs: (json['audio_ms'] as num?)?.toInt() ?? 0,
      words: list<SpeechPoint>('words', SpeechPoint.fromJson),
      sentences: list<SpeechPoint>('sentences', SpeechPoint.fromJson),
      paragraphs: list<ParagraphTiming>('paragraphs', ParagraphTiming.fromJson),
    );
  }
}

/// 逐点构建时间表，并在 [build] 时派生句表与段表。
class SpeechTimelineBuilder {
  SpeechTimelineBuilder({required this.units, required this.granularity});

  final List<SpeechUnit> units;
  final SpeechGranularity granularity;

  final List<SpeechPoint> _words = <SpeechPoint>[];
  int _audioMs = 0;

  set audioMs(int value) => _audioMs = value;

  /// 追加一个词级点（句级路径则每个 unit 追加一次，text 为整句）。
  void addWord(SpeechPoint point) => _words.add(point);

  SpeechTimeline build() {
    // 按时间排序，保证二分前提成立（引擎返回顺序通常正确，但拼接后必须重排）。
    _words.sort((a, b) => a.startMs.compareTo(b.startMs));
    final wordLevel = granularity == SpeechGranularity.word;
    // 句表 = 同一 unit 的点的并集；词级路径要从词点回推句子边界。
    final sentences = <SpeechPoint>[];
    final byUnit = <int, List<SpeechPoint>>{};
    for (final w in _words) {
      (byUnit[w.unitIndex] ??= <SpeechPoint>[]).add(w);
    }
    for (final unit in units) {
      final pts = byUnit[unit.index];
      if (pts == null || pts.isEmpty) continue;
      sentences.add(
        SpeechPoint(
          startMs: pts.first.startMs,
          endMs: wordLevel ? pts.last.endMs : pts.first.endMs,
          charStart: unit.charStart,
          charEnd: unit.charEnd,
          unitIndex: unit.index,
        ),
      );
    }
    // 段表 = 同一 paragraphIndex 的句子的并集。
    final byPara = <int, List<SpeechPoint>>{};
    for (final s in sentences) {
      final p = unitParagraph(s.unitIndex);
      (byPara[p] ??= <SpeechPoint>[]).add(s);
    }
    final paragraphs = <ParagraphTiming>[];
    final keys = byPara.keys.toList()..sort();
    for (final p in keys) {
      final pts = byPara[p]!;
      paragraphs.add(
        ParagraphTiming(
          paragraphIndex: p,
          charStart: pts.first.charStart,
          charEnd: pts.last.charEnd,
          startMs: pts.first.startMs,
          endMs: pts.last.endMs,
        ),
      );
    }
    return SpeechTimeline(
      granularity: granularity,
      audioMs: _audioMs,
      words: wordLevel ? List<SpeechPoint>.unmodifiable(_words) : const [],
      sentences: List<SpeechPoint>.unmodifiable(sentences),
      paragraphs: List<ParagraphTiming>.unmodifiable(paragraphs),
    );
  }

  int unitParagraph(int unitIndex) {
    if (units.isEmpty) return 0;
    return unitIndex.clamp(0, units.length - 1) == unitIndex
        ? units[unitIndex].paragraphIndex
        : units.last.paragraphIndex;
  }
}

SpeechPoint? _lastNotAfter(List<SpeechPoint> points, int ms) {
  final idx = _lastIndexNotAfter(
    points.map((p) => p.startMs).toList(growable: false),
    ms,
  );
  return idx < 0 ? null : points[idx];
}

/// 二分：返回最后一个 `start <= ms` 的下标；全部大于 ms 时返回 -1。
int _lastIndexNotAfter(List<int> starts, int ms) {
  if (starts.isEmpty) return -1;
  var lo = 0;
  var hi = starts.length - 1;
  var ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (starts[mid] <= ms) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

/// 平台音轨的段落级时间点（`AudioTimepoints`）适配到 [SpeechPositions]。
///
/// **委托而非重写**：`paragraphAt` / `startMsOfParagraph` 直接调用原实现，
/// 保证既有听书行为逐项相等；词/句查询返回 `null`，因为音轨侧根本拿不到。
class ParagraphTimelineAdapter implements SpeechPositions {
  const ParagraphTimelineAdapter(this.points);

  final AudioTimepoints points;

  @override
  SpeechGranularity get granularity => SpeechGranularity.paragraph;

  @override
  SpeechPoint? wordAt(int ms) => null;

  @override
  SpeechPoint? sentenceAt(int ms) => null;

  @override
  int paragraphAt(int ms, {required int paragraphCount}) =>
      points.paragraphAt(ms, paragraphCount: paragraphCount);

  @override
  int startMsOfParagraph(int paragraphIndex, {required int paragraphCount}) =>
      points.startMsOfParagraph(paragraphIndex, paragraphCount: paragraphCount);

  /// 与 `AudioTimepoints.offsetMs` 同语义：段落 + 章内比例 → 毫秒。
  int offsetMs({required int paragraphIndex, required double ratio}) =>
      points.offsetMs(paragraphIndex: paragraphIndex, ratio: ratio);
}

/// 一个可用的合成音色。
class TtsVoice {
  const TtsVoice({
    required this.id,
    this.displayName = '',
    this.locale = 'zh-CN',
  });

  /// 引擎内的音色标识（Edge 是短名，如 `zh-CN-XiaoxiaoNeural`）。
  final String id;
  final String displayName;
  final String locale;

  factory TtsVoice.fromJson(Map<String, dynamic> json) => TtsVoice(
    id: json['id'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    locale: json['locale'] as String? ?? 'zh-CN',
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'display_name': displayName,
    'locale': locale,
  };
}

/// 引擎能力位。上层据此决定能显示什么精度、能不能缓存与 seek。
class TtsCaps {
  const TtsCaps({
    this.wordBoundary = false,
    this.offline = false,
    this.needsApiKey = false,
    this.producesFile = true,
    this.container = 'mp3',
    this.granularity,
  });

  /// 能否给出词/字级时间戳。
  final bool wordBoundary;

  /// 精度声明（可选）。
  ///
  /// 默认由 [wordBoundary] 推导（true → 词、false → 句）；少数引擎整块合成、
  /// **连句边界都没有**（如 Piper），必须显式声明 [SpeechGranularity.paragraph]，
  /// 否则 UI 会把它标成「句」—— 那就是伪造精度。
  final SpeechGranularity? granularity;

  /// 实际生效的精度。
  SpeechGranularity get effectiveGranularity =>
      granularity ??
      (wordBoundary ? SpeechGranularity.word : SpeechGranularity.sentence);

  /// 无网络时是否可用。
  final bool offline;

  /// 是否需要用户配置密钥。
  final bool needsApiKey;

  /// 是否产出可播放的音频字节（`false` 意味着不能 seek、不能缓存，
  /// 例如系统 TTS 直接出声 —— 编排层会拒绝这种引擎进主链路）。
  final bool producesFile;

  /// 产物容器：决定缓存文件扩展名与时长换算策略。
  ///
  /// `mp3` 走帧清洗 + CBR 字节换算；`wav`/`pcm` 原样拼接并**必须**在每段里自报
  /// 准确的 `audioMs`（WinRT 系统 TTS、Piper 都属于后者）。
  final String container;
}

/// TTS 侧的错误码。UI 只消费 [TtsException.friendlyText]。
enum TtsErrorCode {
  notConfigured,
  authRejected,
  rateLimited,
  transport,
  emptyAudio,
  invalidCache,
  unsupportedEngine,
  cancelled,
}

/// 合成链路的一次失败。与语音输入侧 `VoiceException` 同一个先例：
/// Dart 侧独立异常，**不进 FFI、不污染 `AquaCode`**。
class TtsException implements Exception {
  const TtsException(this.code, {this.message = '', this.retryable = false});

  final TtsErrorCode code;

  /// 诊断信息，不直接展示给用户。
  final String message;
  final bool retryable;

  String get friendlyText {
    switch (code) {
      case TtsErrorCode.notConfigured:
        return '还没配置可用的朗读语音，可在「我的 → 设置 → 听书」里选择';
      case TtsErrorCode.authRejected:
        return '语音合成服务拒绝了本次请求，请更新到最新版本';
      case TtsErrorCode.rateLimited:
        return '朗读请求太频繁，稍等几秒再试';
      case TtsErrorCode.transport:
        return '网络连接不可用，可改用离线朗读或稍后重试';
      case TtsErrorCode.emptyAudio:
        return '这段内容没能合成出声音，可以重试';
      case TtsErrorCode.invalidCache:
        return '朗读缓存损坏，正在重新合成';
      case TtsErrorCode.unsupportedEngine:
        return '当前设备暂不支持这种朗读方式';
      case TtsErrorCode.cancelled:
        return '朗读已取消';
    }
  }

  @override
  String toString() => 'TtsException(${code.name}): $message';
}
