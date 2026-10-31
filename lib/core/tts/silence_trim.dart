/// 段首/段尾静音裁剪：**为什么**要裁、以及为什么只在帧边界裁。
///
/// 逐段合成天然带 0.2–0.8s 首尾静音，一章几十段累起来就是十几秒空白 ——
/// 听感上表现为「念完一句要顿一下」。裁掉它不需要解码器：词级时间点已经告诉我们
/// 语音从哪开始、到哪结束，剩下的问题只是「怎么裁才不破坏时间轴」。
///
/// 答案：**只按整帧裁**。拼接与时长换算都建立在「字节数 ÷ 码率」上，只要切点落在
/// 帧边界，裁剪后的字节时长就与时间点平移量严格一致；一旦按任意字节切，帧头错位会
/// 让解码器从半个帧开始，后续所有偏移都失去意义。
///
/// 精度不足时**一律不裁**：段级引擎的首点常是 0，拿它当「语音起点」等于盲裁，
/// 会把起音吞掉 —— 这类错误听起来像抢拍，事后极难归因。
library;

import 'dart:typed_data';

import 'mp3_frames.dart';
import 'speech_engine.dart';

/// 裁剪结果。[audio] 是原字节的连续切片（帧边界起、帧边界止）。
class Mp3SilenceTrim {
  const Mp3SilenceTrim({
    required this.audio,
    required this.headMs,
    required this.tailMs,
  });

  /// 裁剪后的帧字节（未裁时就是入参本身）。
  final Uint8List audio;

  /// 段首被裁掉的毫秒数：该段所有时间点必须整体前移这么多。
  final int headMs;

  /// 段尾被裁掉的毫秒数（只影响段总长，不移时间点）。
  final int tailMs;

  bool get trimmed => headMs > 0 || tailMs > 0;
}

/// 按词级时间点裁掉一段 mp3 的首尾静音。
///
/// 判定只有一条：`firstSpeechMs` 之前都是静音，`lastSpeechEndMs` 之后都是静音。
/// 静音不到 [minHeadSilenceMs] / [minTailSilenceMs] 时不裁（省得为几十毫秒冒切音风险）。
Mp3SilenceTrim trimMp3Silence(
  Uint8List frames, {
  required int firstSpeechMs,
  required int lastSpeechEndMs,
  int bitrateKbps = kTtsMp3BitrateKbps,
  int headKeepMs = 80,
  int tailKeepMs = 160,
  int minHeadSilenceMs = 220,
  int minTailSilenceMs = 260,
}) {
  final totalMs = mp3BytesToMs(frames.length, bitrateKbps: bitrateKbps);
  if (frames.isEmpty || totalMs <= 0) {
    return Mp3SilenceTrim(audio: frames, headMs: 0, tailMs: 0);
  }

  var headBytes = 0;
  // 首点必须在段内：早于 0 或晚于段尾都说明时间点与字节不同源，不裁。
  if (firstSpeechMs > 0 && firstSpeechMs <= totalMs) {
    final targetMs = firstSpeechMs - headKeepMs;
    if (targetMs >= minHeadSilenceMs) {
      final offset = mp3FrameOffsetAtOrAfterMs(
        frames,
        targetMs,
        bitrateKbps: bitrateKbps,
      );
      // 帧边界向上取整可能越过 1 帧（Edge 48kbps 下 24ms）：由 headKeepMs 余量吸收。
      // 若越过首点本身，说明帧长异常或时间点错位，放弃裁剪。
      if (offset > 0 &&
          mp3BytesToMs(offset, bitrateKbps: bitrateKbps) <= firstSpeechMs) {
        headBytes = offset;
      }
    }
  }

  var endBytes = frames.length;
  if (lastSpeechEndMs > 0 && lastSpeechEndMs < totalMs) {
    if (totalMs - lastSpeechEndMs >= minTailSilenceMs) {
      final offset = mp3FrameOffsetAtOrAfterMs(
        frames,
        lastSpeechEndMs + tailKeepMs,
        bitrateKbps: bitrateKbps,
      );
      // 至少要留到末点之后（offset 是「第一个累计 >= 目标」的帧尾，天然 > 目标）；
      // 若已经到段尾则等于没裁，直接不动。
      if (offset > headBytes && offset < frames.length) endBytes = offset;
    }
  }

  if (headBytes == 0 && endBytes == frames.length) {
    return Mp3SilenceTrim(audio: frames, headMs: 0, tailMs: 0);
  }
  return Mp3SilenceTrim(
    audio: Uint8List.sublistView(frames, headBytes, endBytes),
    headMs: mp3BytesToMs(headBytes, bitrateKbps: bitrateKbps),
    tailMs: totalMs - mp3BytesToMs(endBytes, bitrateKbps: bitrateKbps),
  );
}
