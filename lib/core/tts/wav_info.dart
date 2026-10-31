/// 极简 WAV(RIFF) 头解析：只为拿到**时长**与采样参数。
///
/// 为什么需要它：wav 引擎（Windows 系统语音 / Piper）在 `TtsSegment` 里必须自报
/// `audioMs`；如果引擎自报值不可靠（进程退出码 0 但流被截断），编排层会拿错时长去
/// 推进 `offsetBaseMs`，整章时间点就全歪。这里从**容器本身**算一遍，可与自报值交叉校验。
///
/// 只支持 PCM/浮点未压缩布局（`fmt ` chunk 里 `audioFormat` = 1/3）；
/// 遇到其它编码或结构损坏返回 `null`，由调用方决定如何降级。
library;

import 'dart:typed_data';

class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// 实际音频数据字节数（`data` chunk 的长度）。
  final int dataBytes;

  int get byteRate => sampleRate * channels * (bitsPerSample ~/ 8);

  /// 时长（毫秒）。`byteRate <= 0` 时返回 0。
  int get durationMs {
    if (byteRate <= 0) return 0;
    return dataBytes * 1000 ~/ byteRate;
  }

  /// 解析 RIFF/WAVE。失败一律返回 `null`（不抛，调用方按"引擎自报不可信"处理）。
  static WavInfo? parse(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final data = ByteData.sublistView(bytes);
    if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') return null;

    var offset = 12;
    int? sampleRate;
    int? channels;
    int? bits;
    int? dataBytes;
    while (offset + 8 <= bytes.length) {
      final id = _tag(bytes, offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        final audioFormat = data.getUint16(body, Endian.little);
        // 1 = PCM，3 = IEEE float；其余（ADPCM/MP3-in-WAV…）不在这里装懂。
        if (audioFormat != 1 && audioFormat != 3) return null;
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        // 有些写出器把 size 写成 0xFFFFFFFF（流式）：按剩余字节兜底。
        final remaining = bytes.length - body;
        dataBytes = size > remaining ? remaining : size;
      }
      // chunk 必须按偶数对齐推进。
      offset = body + size + (size.isOdd ? 1 : 0);
    }

    if (sampleRate == null ||
        channels == null ||
        bits == null ||
        dataBytes == null) {
      return null;
    }
    if (sampleRate <= 0 || channels <= 0 || bits <= 0) return null;
    return WavInfo(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bits,
      dataBytes: dataBytes,
    );
  }

  static String _tag(Uint8List bytes, int at) =>
      String.fromCharCodes(bytes.sublist(at, at + 4));
}
