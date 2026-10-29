import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// 语音输入的纯逻辑件：电平换算、静音端点检测、WAV 封装。
/// 不依赖任何插件，全部可单测。

/// RMS 振幅（0..32767）→ dBFS（约 -60..0）。
double rmsToDbfs(int rms, {double maxAmplitude = 32767}) {
  if (rms <= 0) return -60;
  final ratio = math.min(rms / maxAmplitude, 1.0);
  final db = 20 * math.log(ratio) / math.ln10;
  return db < -60 ? -60 : db;
}

/// 电平是否低于静音阈值（voicekey/opencode-voice 同一档位：约 -45dBFS）。
bool isSilenceDbfs(double dbfs, {double thresholdDbfs = -45}) =>
    dbfs < thresholdDbfs;

/// 静音端点检测：说过话之后连续静音 [silenceMs] 即可结束录音。
///
/// 用户点了麦克风但一直没出声时 [heardSpeech] 保持 false，调用方用
/// 最大时长兜底（默认 15s）。
class SilenceVad {
  SilenceVad({
    this.silenceMs = 1500,
    this.thresholdDbfs = -45,
  });

  final int silenceMs;
  final double thresholdDbfs;

  DateTime? _lastLoudAt;
  bool _heardSpeech = false;

  bool get heardSpeech => _heardSpeech;

  /// 持续喂入当前电平；返回 true = 应结束录音。
  bool feed(double dbfs, DateTime now) {
    if (!isSilenceDbfs(dbfs, thresholdDbfs: thresholdDbfs)) {
      _lastLoudAt = now;
      _heardSpeech = true;
      return false;
    }
    if (!_heardSpeech || _lastLoudAt == null) return false;
    return now.difference(_lastLoudAt!).inMilliseconds >= silenceMs;
  }

  void reset() {
    _lastLoudAt = null;
    _heardSpeech = false;
  }
}

/// 16-bit PCM → WAV 文件字节（含 44 字节 RIFF 头）。
Uint8List buildWavBytes(Uint8List pcmBytes,
    {int sampleRate = 16000, int channels = 1, int bitsPerSample = 16}) {
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataLen = pcmBytes.length;
  final out = BytesBuilder();
  void writeAscii(String s) => out.add(ascii.encode(s));
  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  void u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  writeAscii('RIFF');
  u32(36 + dataLen);
  writeAscii('WAVE');
  writeAscii('fmt ');
  u32(16);
  u16(1); // PCM
  u16(channels);
  u32(sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  writeAscii('data');
  u32(dataLen);
  out.add(pcmBytes);
  return out.takeBytes();
}
