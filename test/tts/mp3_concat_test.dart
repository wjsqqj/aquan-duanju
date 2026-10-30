import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/mp3_frames.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造 MPEG-2 Layer III 48kbps / 24kHz 的帧（与 Edge 输出同参数）：每帧 144 字节 = 24ms。
///
/// 填充字节刻意避开 0xFF，否则帧体内会出现伪同步，测不出「逐字节找同步」的行为。
Uint8List frames(int count) {
  final out = Uint8List(count * 144);
  for (var f = 0; f < count; f++) {
    final o = f * 144;
    out[o] = 0xFF;
    out[o + 1] = 0xF3; // 同步尾 111 + MPEG2(10) + LayerIII(01) + 无 CRC(1)
    out[o + 2] = 0x64; // 码率索引 6(48kbps) + 采样索引 1(24000) + 无填充 + private
    out[o + 3] = 0x40; // mono
    for (var j = 4; j < 144; j++) {
      out[o + j] = 0x20 + (j % 60);
    }
  }
  return out;
}

/// 把一帧改成带 [token] 的元数据帧（Xing/Info 就落在帧头之后的窗口里）。
Uint8List withToken(Uint8List oneFrame, List<int> token, {int at = 24}) {
  expect(oneFrame.length, 144);
  oneFrame.setRange(at, at + token.length, token);
  return oneFrame;
}

/// synchsafe（每字节低 7 位）编码，ID3v2 的长度字段就是这个格式。
List<int> synchsafe(int value) => <int>[
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];

/// 一张 ID3v2 标签：10 字节头 + [payload] 字节内容（可选 10 字节页脚）。
Uint8List id3v2({int payload = 16, int flags = 0, bool footer = false}) {
  final out = Uint8List(10 + payload + (footer ? 10 : 0));
  out[0] = 0x49; // I
  out[1] = 0x44; // D
  out[2] = 0x33; // 3
  out[3] = 2; // version major
  out[4] = 4; // version minor
  out[5] = flags;
  final size = synchsafe(payload);
  out[6] = size[0];
  out[7] = size[1];
  out[8] = size[2];
  out[9] = size[3];
  for (var i = 10; i < 10 + payload; i++) {
    out[i] = 0x20; // 标签内容用空格：既非 0 也非 0xFF
  }
  if (footer) {
    out[10 + payload] = 0x49;
    out[10 + payload + 1] = 0x44;
    out[10 + payload + 2] = 0x33;
  }
  return out;
}

Uint8List concat(List<List<int>> parts) {
  final out = <int>[];
  for (final part in parts) {
    out.addAll(part);
  }
  return Uint8List.fromList(out);
}

const List<int> _xing = <int>[0x58, 0x69, 0x6E, 0x67]; // 'Xing'
const List<int> _info = <int>[0x49, 0x6E, 0x66, 0x6F]; // 'Info'

void main() {
  group('帧清洗', () {
    test('纯帧序列原样保留', () {
      expect(extractMp3AudioFrames(frames(3)), hasLength(3 * 144));
    });

    test('剔除 ID3v2，长度按 synchsafe 解码', () {
      final dirty = concat(<List<int>>[id3v2(payload: 1000), frames(2)]);
      final clean = extractMp3AudioFrames(dirty);
      expect(clean, hasLength(2 * 144));
      // 首字节必须是帧同步：说明标签整段被跳过，而不是逐字节残留了头。
      expect(clean[0], 0xFF);
      expect(clean[1], 0xF3);
    });

    test('多张标签串联也全部剔除', () {
      final dirty = concat(<List<int>>[
        id3v2(payload: 8),
        id3v2(payload: 16),
        frames(2),
      ]);
      expect(extractMp3AudioFrames(dirty), hasLength(2 * 144));
    });

    test('flags 的 footer 位：页脚不计入长度，也要一起跳过', () {
      final dirty = concat(<List<int>>[
        id3v2(payload: 24, flags: 0x10, footer: true),
        frames(2),
      ]);
      expect(extractMp3AudioFrames(dirty), hasLength(2 * 144));
    });

    test('首帧 Xing 头被剔除，后续音频帧不受影响', () {
      final dirty = concat(<List<int>>[withToken(frames(1), _xing), frames(3)]);
      expect(extractMp3AudioFrames(dirty), hasLength(3 * 144));
    });

    test('Info 头同样被剔除', () {
      final dirty = concat(<List<int>>[
        withToken(frames(1), _info, at: 36),
        frames(2),
      ]);
      expect(extractMp3AudioFrames(dirty), hasLength(2 * 144));
    });

    test('非帧前导垃圾字节被跳过', () {
      final dirty = concat(<List<int>>[
        <int>[0x00, 0x11, 0x22, 0xFF, 0x11], // 半截同步 + 垃圾
        frames(2),
      ]);
      expect(extractMp3AudioFrames(dirty), hasLength(2 * 144));
    });

    test('末段被截断：丢掉不完整的尾帧', () {
      final full = frames(3);
      final dirty = concat(<List<int>>[
        full.sublist(0, 2 * 144),
        full.sublist(2 * 144, 2 * 144 + 100),
      ]);
      expect(extractMp3AudioFrames(dirty), hasLength(2 * 144));
    });

    test('全零占位字节清洗后为空（不能当音频）', () {
      final zeros = Uint8List(144 * 8);
      expect(extractMp3AudioFrames(zeros), isEmpty);
      expect(allZeroBytes(zeros), isTrue);
      expect(allZeroBytes(frames(1)), isFalse);
      expect(containsAudioFrame(zeros), isFalse);
      expect(containsAudioFrame(frames(1)), isTrue);
      expect(
        containsAudioFrame(concat(<List<int>>[id3v2(payload: 32), frames(1)])),
        isTrue,
      );
    });
  });

  group('CBR 字节 ↔ 时长', () {
    test('48kbps 即 bytes / 6', () {
      for (final bytes in <int>[6, 60, 600, 6000, 144 * 7]) {
        expect(mp3BytesToMs(bytes, bitrateKbps: 48), bytes ~/ 6);
      }
      expect(mp3BytesToMs(6000, bitrateKbps: 48), 1000);
      expect(mp3BytesToMs(144, bitrateKbps: 48), 24);
      expect(mp3BytesToMs(0), 0);
      expect(mp3BytesToMs(100, bitrateKbps: 0), 0);
    });

    test('整章时长 = 总字节换算，可按段线性相加', () {
      final a = extractMp3AudioFrames(frames(4));
      final b = extractMp3AudioFrames(frames(7));
      final joined = extractMp3AudioFrames(concat(<List<int>>[a, b]));
      expect(joined.length, a.length + b.length);
      expect(
        mp3BytesToMs(joined.length),
        mp3BytesToMs(a.length) + mp3BytesToMs(b.length),
      );
    });

    test('容器头若留着会虚增时长（所以必须剔除）', () {
      final dirty = concat(<List<int>>[id3v2(payload: 2000), frames(3)]);
      final clean = extractMp3AudioFrames(dirty);
      expect(
        mp3BytesToMs(dirty.length),
        greaterThan(mp3BytesToMs(clean.length)),
      );
      expect(mp3BytesToMs(clean.length), 3 * 24);
    });
  });
}
