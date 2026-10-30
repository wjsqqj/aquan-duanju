/// Edge（readaloud）合成引擎：把 [SpeechJob] 变成 [TtsSegment]。
///
/// 职责边界（design.md §4 的接缝）：
/// - **时间**：引擎只负责「本次 job 内部」的对齐 —— 内部再按 4096 字节切块时，
///   用本地 CBR 字节累加算出每块的 tick 补偿；`job.offsetBaseMs` 由 composer 注入，
///   引擎把它加到每个返回点上（硬契约 1）。累计偏移不在引擎里算，因为它看不到别的 job。
/// - **字符**：返回的 `charStart/charEnd` 相对 `job.text`。`removeIncompatibleCharacters`
///   只把控制字符换成空格、**长度不变**，所以在清洗串上算出的下标即 `job.text` 的下标。
/// - **词级**：多字符 token 在这里就 `expandPerChar()` 展开成近似字级点，消费端不必
///   知道 Edge 的分词粒度。
///
/// 一条硬约束：**每次 `synthesize` 都可能开多条 WebSocket 连接**（每个内部块一条，
/// 说明书 §3），所以块与块之间是顺序的、不并发；并发节流属于上层（步骤 7）。
library;

import 'dart:typed_data';

import '../mp3_frames.dart';
import '../speech_engine.dart';
import '../tts_models.dart';
import 'edge_constants.dart';
import 'edge_frames.dart';
import 'edge_ssml.dart';
import 'edge_stream.dart';
import 'edge_token.dart';
import 'edge_voices.dart';

/// 上游 `Metadata[].Type` 的两种取值。
///
/// 只把 `WordBoundary` 变成时间点：composer 的表是**词表**（`_absorb` 逐点
/// `addWord`），混进句级点会让高亮按整句均分，精度反而退化。句子边界由
/// `SpeechTimelineBuilder` 从 speak unit 反推（`speech_unit.dart` 已有单元坐标），
/// 所以 `SentenceBoundary` 在这里被安全地丢弃。
const String _wordBoundaryType = 'WordBoundary';

/// Edge 在线引擎。
class EdgeSpeechEngine implements SpeechEngine {
  EdgeSpeechEngine({
    EdgeEndpointPreset? preset,
    this.proxy = '',
    String rate = kEdgeDefaultRate,
    String volume = kEdgeDefaultVolume,
    String pitch = kEdgeDefaultPitch,
    WsFactory? wsFactory,
    HttpClientFactory? httpClientFactory,
    DrmClock? clock,
    DateTime Function()? now,
    this.connectTimeout = kEdgeConnectTimeout,
    this.receiveTimeout = kEdgeReceiveTimeout,
  }) : preset = preset ?? kEdgeDefaultPreset,
       // 韵律参数在构造时就校验：设置页存坏值要在最早的地方炸出来（硬契约 4），
       // 而不是等到朗读第三条时才在 SSML 里静默拼出非法属性。
       rate = validateProsody('rate', rate, kEdgeRatePattern),
       volume = validateProsody('volume', volume, kEdgeRatePattern),
       pitch = validateProsody('pitch', pitch, kEdgePitchPattern),
       _wsFactory = wsFactory ?? edgeIoWebSocket,
       _httpClientFactory = httpClientFactory ?? edgeIoHttpClient,
       _clock = clock ?? DrmClock.shared,
       _now = now ?? DateTime.now {
    // 会话对象是无状态的（每次 runChunk 自己建一条连接），所以整个引擎共用一个，
    // 也保证上面归一化过的字段就是会话真正使用的配置。
    _session = EdgeSession(
      // 构造函数体里同名标识符指向**形参**，所以可空的 `preset` 必须写 this.
      // （写成 `preset` 会拿到尚未归一化的 null）。
      preset: this.preset,
      wsFactory: _wsFactory,
      httpClientFactory: _httpClientFactory,
      clock: _clock,
      proxy: proxy,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      now: _now,
    );
  }

  /// 端点四元组。403 耗尽纠偏机会后，上层用它换端点（见 [fallbackPreset]）。
  final EdgeEndpointPreset preset;

  /// 代理（`host:port`）；空串表示 DIRECT，**绝不读环境变量**。
  final String proxy;

  final String rate;
  final String volume;
  final String pitch;

  final WsFactory _wsFactory;
  final HttpClientFactory _httpClientFactory;
  final DrmClock _clock;
  final DateTime Function() _now;

  /// 连接与单次收包超时（硬契约 9：10s / 60s，总时长不限）。
  final Duration connectTimeout;
  final Duration receiveTimeout;
  late final EdgeSession _session;

  /// 短名 → Azure 全名的小缓存：音色在一次朗读里不变，没必要每块都跑正则。
  final Map<String, String> _fullNameCache = <String, String>{};

  /// 进程内音色列表缓存（硬契约 11：只拉一次）。
  List<TtsVoice>? _voices;

  @override
  String get id => 'edge';

  @override
  TtsCaps get caps => const TtsCaps(
    wordBoundary: true,
    offline: false,
    needsApiKey: false,
    producesFile: true,
  );

  /// 403 降级顺序里的下一个端点；已经是最后一个时返回 `null`。
  ///
  /// 本引擎**不会**在一次请求里静默换 host（硬契约 10 只允许一次时钟纠偏重试）：
  /// 端点漂移必须让上层看得见，由它显式重建引擎。
  EdgeEndpointPreset? get fallbackPreset {
    final order = edgeEndpointFallbackOrder(preset);
    return order.length > 1 ? order[1] : null;
  }

  @override
  Future<List<TtsVoice>> voices() async {
    final cached = _voices;
    if (cached != null) return cached;
    final list = await edgeListVoices(
      preset: preset,
      httpClientFactory: _httpClientFactory,
      clock: _clock,
      proxy: proxy,
      now: _now,
    );
    // 只有成功拿到列表才缓存：失败时 `edgeListVoices` 抛异常，不会把空结果钉住。
    _voices = list;
    return list;
  }

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    final source = removeIncompatibleCharacters(job.text);
    final ranges = splitSpeakRanges(source);
    if (ranges.isEmpty) {
      throw TtsException(
        TtsErrorCode.emptyAudio,
        message: 'edge：job.text 没有可合成的字符（len=${job.text.length}）',
      );
    }
    final voice = _fullVoiceName(job.voice.id);
    final audio = BytesBuilder(copy: false);
    final points = <SpeechPoint>[];
    final stats = TtsStats();
    // 词 token 在清洗串上的推进游标：服务端一定按朗读顺序回吐 boundary，
    // 所以「从游标起第一次命中」就是它的落点，重复词不会被错位。
    var cursor = 0;

    for (var i = 0; i < ranges.length; i++) {
      final range = ranges[i];
      final result = await _session.runChunk(
        buildSsml(
          voice: voice,
          // 先切块再转义：实体不会被劈开（说明书 §7.1），且预算按转义后的字节数核算。
          text: ssmlEscapeText(range.slice(source)),
          rate: rate,
          volume: volume,
          pitch: pitch,
          escapeText: false,
        ),
      );
      // 音频先洗成纯帧再累计字节：偏移补偿必须和 composer 的 `mp3BytesToMs`
      // 用同一个口径（ID3/Xing 头不计入时长，上游数的也是清洗后的字节）。
      final frames = extractMp3AudioFrames(result.audio);
      if (frames.isEmpty) {
        throw TtsException(
          TtsErrorCode.emptyAudio,
          message: 'edge：第 $i/$ranges.length 块清洗后没有音频帧',
          retryable: true,
        );
      }
      audio.add(frames);
      stats.chunkBytes = frames.length;

      for (final EdgeBoundary boundary in result.boundaries) {
        if (boundary.type != _wordBoundaryType) continue;
        final token = boundary.text;
        if (token.isEmpty) continue;
        final start = _locate(source, range, cursor, token);
        final end = (start + token.length) > range.end
            ? range.end
            : start + token.length;
        if (end <= start) continue;
        // 块间的 tick 补偿 = 之前所有块的字节省量（硬契约 8：只用本地 CBR 字节累加，
        // 上游那套 `lastDurationOffset + 8750000` 是废弃公式，不实现）。
        final baseTicks = stats.offsetCompensationTicks;
        final startTicks = baseTicks + boundary.offsetTicks;
        final endTicks = startTicks + boundary.durationTicks;
        final point = SpeechPoint(
          startMs: edgeTicksToMs(startTicks) + job.offsetBaseMs,
          endMs: edgeTicksToMs(endTicks) + job.offsetBaseMs,
          // 清洗串与 job.text 等长，下标可直接当 job.text 的下标用。
          charStart: start,
          charEnd: end,
          unitIndex: 0,
          text: token,
        );
        // 词级 → 近似字级：展开发生在引擎侧，composer 与消费端不必知道差别。
        points.addAll(point.expandPerChar());
        cursor = end;
      }
      stats.finishChunk();
    }

    if (points.isEmpty) {
      // 有音频但一个时间点都没解析出来 = 协议漂移（服务端改了 metadata 结构）。
      throw TtsException(
        TtsErrorCode.emptyAudio,
        message:
            'edge：没有解析到 WordBoundary'
            '${_diagnostic(ranges.length)}',
        retryable: true,
      );
    }
    final bytes = audio.toBytes();
    return TtsSegment(
      audio: bytes,
      points: points,
      audioMs: mp3BytesToMs(bytes.length),
    );
  }

  @override
  Future<void> dispose() async {
    // 没有常驻资源：连接在每次 `runChunk` 的 finally 里关闭，HTTP 客户端同理，
    // 时钟纠偏量属于 [DrmClock.shared]（进程共享，不该被单个引擎清掉）。
    _voices = null;
    _fullNameCache.clear();
  }

  /// token 落点：优先在 `[cursor, range.end]` 内精确命中；命中不了就退化为游标顺推
  /// （服务端可能对全角标点做了分词折叠，此时 token 与原文对不上，但**顺序仍成立**，
  /// 用游标继续走比丢弃该点更好——丢点的代价是高亮少一格，游标断档的代价是后面全串）。
  int _locate(String source, EdgeSpeakRange range, int cursor, String token) {
    final at = source.indexOf(token, cursor);
    if (at >= range.start && at + token.length <= range.end) return at;
    final fallback = cursor < range.start ? range.start : cursor;
    return fallback > range.end ? range.end : fallback;
  }

  String _diagnostic(int chunkCount) =>
      chunkCount > 1 ? '（$chunkCount 块全为空）' : '';

  /// 短名 → 服务端要的 Azure 全名。识别失败是**配置问题**，用 `notConfigured`
  /// 上报（`FormatException` 会绕过错误分类，用户只看到「未知错误」）。
  String _fullVoiceName(String shortName) {
    final name = shortName.trim().isEmpty
        ? kEdgeFallbackVoice
        : shortName.trim();
    return _fullNameCache.putIfAbsent(name, () {
      try {
        return azureVoiceName(name);
      } on FormatException catch (e) {
        throw TtsException(
          TtsErrorCode.notConfigured,
          message: 'edge：${e.message}',
        );
      }
    });
  }
}
