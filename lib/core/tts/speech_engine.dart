/// 朗读合成引擎的接口层（与 `lib/core/player/player_engine.dart` 并列，不替代它）。
///
/// 分工接缝只有一条：引擎合成**一小段**（一个 chunk），并把 composer 注入的
/// [SpeechJob.offsetBaseMs] 加到自己返回的时间点上；累计偏移只有 composer 能算，
/// 因为它才知道拼接后的总字节数（`.trellis/tasks/10-30-listen-speech-engine-chain/design.md` §4）。
///
/// 倍速**不进**引擎：时间点一律是媒体时间轴毫秒，播放倍速由 `PlayerEngine.setRate` 处理。
library;

import 'dart:typed_data';

import 'tts_models.dart';

/// Edge 上游固定输出 `audio-24khz-48kbitrate-mono-mp3`：CBR 48kbps。
/// 这是「字节数 ↔ 毫秒」换算的唯一依据，别按各引擎自报时长算。
const int kTtsMp3BitrateKbps = 48;

/// 单个合成请求允许的文本上限（字符数）。留出 SSML 包装余量，与 design.md §5.7 一致。
const int kTtsMaxChunkChars = 2000;

/// 一次合成请求。
class SpeechJob {
  const SpeechJob({
    required this.text,
    required this.voice,
    required this.offsetBaseMs,
    required this.requestIndex,
  });

  /// 待合成文本，恒为章内明文的一个**连续切片**（composer 保证），因此引擎返回的
  /// 字符位可以直接线性平移回章内绝对坐标。
  final String text;

  /// 用哪个音色合成（引擎 id 由 [SpeechEngine.id] 提供，不在这里重复）。
  final TtsVoice voice;

  /// 本段在整章音频中的起点（毫秒）。引擎把它加到返回的每个点上。
  ///
  /// 这一项是自研客户端相对上游 `edge_dart` 补上的关键能力：上游没有外部注入
  /// 入口，多段拼接时只能靠猜的 0.875s 块间缝隙，长章节必然漂移。
  final int offsetBaseMs;

  /// 世代号（控制器的 `_epoch`）。引擎可用于识别「这次请求已经不是当前任务」，
  /// 但真正的丢弃发生在 composer 的 await 之后。
  final int requestIndex;
}

/// 一段合成结果。
class TtsSegment {
  const TtsSegment({
    required this.audio,
    required this.points,
    required this.audioMs,
    this.bitrateKbps = kTtsMp3BitrateKbps,
  });

  /// 该段音频字节（可以带 ID3v2 / Xing 头，拼接前由 composer 逐段清洗）。
  final Uint8List audio;

  /// 该段的时间点：
  /// - `startMs/endMs` 是**已加 [SpeechJob.offsetBaseMs] 的整章媒体时间**；
  /// - `charStart/charEnd` 是**相对 [SpeechJob.text]** 的字符位（引擎不知道整章文本）；
  /// - `unitIndex` 由引擎随意填（通常是 0），composer 会按字符坐标重算；
  /// - `text` 是引擎返回的 token 原文。
  ///
  /// 词级 token 若多于 1 字符，展开成近似字级点发生在**引擎侧**（消费端不知道差别）。
  final List<SpeechPoint> points;

  /// 引擎自报的本段时长（毫秒）。仅作诊断：整章时长一律用字节数换算，不用它求和。
  final int audioMs;

  /// 本段音频码率（kbps，CBR），决定字节 ↔ 毫秒的换算系数。
  final int bitrateKbps;
}

/// 合成能力接口。实现必须是无 `BuildContext` 的纯 Dart 对象，可被控制器长期持有。
abstract class SpeechEngine {
  /// 引擎标识，进缓存键（`'edge'` / `'azure'` / `'winrt'` …）。
  String get id;

  /// 能力位。上层据此决定能显示什么精度、能不能缓存与 seek。
  TtsCaps get caps;

  /// 可用音色。实现应带进程内缓存，失败时抛 [TtsException]。
  Future<List<TtsVoice>> voices();

  /// 合成一段音频。失败必须抛 [TtsException]（分类见 design.md §8），不要返回空字节。
  Future<TtsSegment> synthesize(SpeechJob job);

  Future<void> dispose();
}

/// 空音频与占位字节的判定阈值（字节）。
///
/// 合成的最短一段也远大于这个数；低于它的一律当作「截断/占位」，不能当结果使用。
const int kTtsMinSegmentBytes = 256;
