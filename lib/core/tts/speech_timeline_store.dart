/// 时间点文件（`.jsonl`）的读写。与音频 `.mp3` 成对存在，见 `tts_cache.dart`。
///
/// 为什么用 JSONL 而不是一整个 JSON 对象：
/// - 合成是逐段推进的，追加一行就是一个段的点，中途失败也留下可用的前半部分；
/// - 解析按行独立，尾行被截断只丢那一行，不会让整张表作废（但仍会被缓存层
///   判为「点太少/不匹配」而清理，见 `TtsCache.lookup`）。
///
/// 首行是元信息（版本、精度位、整章时长、正文指纹），其余每行一个点，用 `k`
/// 区分词/句/段三种表；点本身的字段沿用 [SpeechPoint.toJson] 的紧凑键名。
library;

import 'dart:convert';
import 'dart:io';

import 'tts_models.dart';

/// 一份读出来的时间点文件：表 + 写它时的正文指纹。
class SpeechTimelineFile {
  const SpeechTimelineFile({required this.timeline, this.signature = ''});

  final SpeechTimeline timeline;

  /// 正文 FNV-1a 指纹（`contentSignature` 同一口径）。空串表示旧文件没写，无法校验。
  final String signature;

  int get pointCount =>
      timeline.words.length +
      timeline.sentences.length +
      timeline.paragraphs.length;
}

class SpeechTimelineStore {
  const SpeechTimelineStore();

  /// 结构版本：字段语义变了就加一，读侧只接受当前版本。
  static const int schemaVersion = 1;

  /// 序列化成 JSONL 文本（含结尾换行）。
  String encode(SpeechTimeline timeline, {String signature = ''}) {
    final buffer = StringBuffer();
    buffer.write(
      jsonEncode(<String, dynamic>{
        'v': schemaVersion,
        'granularity': timeline.granularity.name,
        'audio_ms': timeline.audioMs,
        if (signature.isNotEmpty) 'sig': signature,
      }),
    );
    buffer.write('\n');
    for (final w in timeline.words) {
      buffer.write(jsonEncode(<String, dynamic>{'k': 'w', ...w.toJson()}));
      buffer.write('\n');
    }
    for (final s in timeline.sentences) {
      buffer.write(jsonEncode(<String, dynamic>{'k': 's', ...s.toJson()}));
      buffer.write('\n');
    }
    for (final p in timeline.paragraphs) {
      buffer.write(jsonEncode(<String, dynamic>{'k': 'p', ...p.toJson()}));
      buffer.write('\n');
    }
    return buffer.toString();
  }

  /// 解析 JSONL 文本。
  ///
  /// 返回 `null` 表示「这份文件不可用」：缺元信息行、版本不符、或者一个点都没有。
  /// 单行坏数据（截断/非 JSON）跳过，不牵连其他行 —— 但最终点数必须 > 0。
  SpeechTimelineFile? decode(String text) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return null;
    final meta = _jsonLine(lines.first);
    if (meta == null) return null;
    if ((meta['v'] as num?)?.toInt() != schemaVersion) return null;
    final granularity = SpeechGranularity.parse(meta['granularity'] as String?);
    final audioMs = (meta['audio_ms'] as num?)?.toInt() ?? 0;
    final words = <SpeechPoint>[];
    final sentences = <SpeechPoint>[];
    final paragraphs = <ParagraphTiming>[];
    for (var i = 1; i < lines.length; i++) {
      final row = _jsonLine(lines[i]);
      if (row == null) continue;
      switch (row['k']) {
        case 'w':
          words.add(SpeechPoint.fromJson(row));
        case 's':
          sentences.add(SpeechPoint.fromJson(row));
        case 'p':
          paragraphs.add(ParagraphTiming.fromJson(row));
      }
    }
    if (words.isEmpty && sentences.isEmpty && paragraphs.isEmpty) return null;
    return SpeechTimelineFile(
      signature: meta['sig'] as String? ?? '',
      timeline: SpeechTimeline(
        granularity: granularity,
        audioMs: audioMs,
        words: List<SpeechPoint>.unmodifiable(words),
        sentences: List<SpeechPoint>.unmodifiable(sentences),
        paragraphs: List<ParagraphTiming>.unmodifiable(paragraphs),
      ),
    );
  }

  Future<void> write(
    File file,
    SpeechTimeline timeline, {
    String signature = '',
  }) async {
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // 时间点文件是「读一次用一整章」，直接覆盖写；不做原子换名是为了与音频写入
    // 保持同一套失败语义：任意一半没写完，缓存层都会判无效并成对删除。
    await file.writeAsString(
      encode(timeline, signature: signature),
      flush: true,
    );
  }

  Future<SpeechTimelineFile?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      return decode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _jsonLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
