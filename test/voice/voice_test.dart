import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/voice/vad.dart';

void main() {
  group('rmsToDbfs / isSilenceDbfs', () {
    test('满幅 ≈ 0dB，静音 < -45dB', () {
      expect(rmsToDbfs(32767), closeTo(0, 0.01));
      expect(rmsToDbfs(0), -60);
      expect(rmsToDbfs(32767 ~/ 10), closeTo(-20, 0.1));
      expect(rmsToDbfs(-5, maxAmplitude: 32767) < -45, isTrue,
          reason: '负数 RMS 视为静音');
      expect(isSilenceDbfs(-50), isTrue);
      expect(isSilenceDbfs(-30), isFalse);
      expect(isSilenceDbfs(-45), isFalse, reason: '恰好等于阈值不算静音');
      expect(isSilenceDbfs(-45.1), isTrue);
    });
  });

  group('SilenceVad 静音端点检测', () {
    final t0 = DateTime(2026, 10, 30, 12);

    test('没说过话不结束（超时兜底由调用方负责）', () {
      final vad = SilenceVad();
      var now = t0;
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(milliseconds: 100));
        expect(vad.feed(-60, now), isFalse, reason: '一直静音也不该触发');
      }
      expect(vad.heardSpeech, isFalse);
    });

    test('说话后静音 1.5s 触发结束；中途出声重置计时', () {
      final vad = SilenceVad();
      var now = t0;
      now = now.add(const Duration(milliseconds: 200));
      expect(vad.feed(-20, now), isFalse); // 开始说话
      expect(vad.heardSpeech, isTrue);
      now = now.add(const Duration(milliseconds: 1400));
      expect(vad.feed(-60, now), isFalse, reason: '静音 1.4s 还不够');
      now = now.add(const Duration(milliseconds: 200));
      expect(vad.feed(-60, now), isTrue, reason: '累计静音 1.6s ≥ 1.5s');

      // 重新开始一次会话语义：reset 后重新判定。
      vad.reset();
      now = now.add(const Duration(milliseconds: 100));
      expect(vad.feed(-15, now), isFalse);
      now = now.add(const Duration(milliseconds: 1600));
      expect(vad.feed(-60, now), isTrue);
    });

    test('说话与静音交替：只要静音间隔不连续就不结束', () {
      final vad = SilenceVad();
      var now = t0;
      for (var i = 0; i < 10; i++) {
        now = now.add(const Duration(milliseconds: 300));
        vad.feed(-10, now); // 每次都出一点声
        now = now.add(const Duration(milliseconds: 1000));
        expect(vad.feed(-60, now), isFalse, reason: '1.0s 静音 < 1.5s');
      }
    });
  });

  group('buildWavBytes', () {
    test('RIFF 头与数据长度', () {
      // 10 个采样点（16bit 单声道）= 20 字节 PCM。
      final pcm = Uint8List(20);
      final wav = buildWavBytes(pcm, sampleRate: 16000);
      expect(wav.length, 44 + 20);
      expect(utf8.decode(wav.sublist(0, 4)), 'RIFF');
      expect(utf8.decode(wav.sublist(8, 12)), 'WAVE');
      expect(utf8.decode(wav.sublist(36, 40)), 'data');
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(4, Endian.little), 36 + 20); // RIFF size
      expect(bd.getUint32(24, Endian.little), 16000); // sample rate
      expect(bd.getUint16(22, Endian.little), 1); // channels
      expect(bd.getUint16(34, Endian.little), 16); // bits
      expect(bd.getUint32(40, Endian.little), 20); // data size
    });
  });
}
