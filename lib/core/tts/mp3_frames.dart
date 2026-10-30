/// mp3 帧级清洗：**为什么**拼接前必须逐段剔除容器头。
///
/// 整章时长与累计偏移一律用「字节数 ÷ 码率」换算（48kbps CBR → 6000 字节/秒 →
/// `bytes / 6` 毫秒）。这条等式成立的前提是文件里**只有 MPEG 音频帧**：
/// - 每张 ID3v2 标签、每个 Xing/Info 首帧、每段非音频垃圾字节，都会让「字节数」
///   比真实音频多算出时间，于是后面的词级点整体偏后 —— 章节越长偏得越多，
///   这正是 readest / edge_dart 那条「靠猜 0.875s 块间缝隙」路线的病根；
/// - 反过来，截断的尾帧留着会让解码器在结尾爆音，也一并丢掉。
///
/// 所以这里做的事：跳过 ID3v2（含 synchsafe 长度与 flags，可能有多张标签）、
/// 丢掉首帧 Xing/Info、丢弃不是帧前导的垃圾字节、丢弃长度超出剩余数据的截断尾帧。
/// 纯函数，不碰文件系统，便于用构造字节序列做单测。
library;

import 'dart:typed_data';

import 'speech_engine.dart';

/// 字节数 → 媒体时间毫秒。
///
/// `48kbps = 6000 字节/秒`，所以 `bytes / 6`；写成通用形式以便未来接入别的码率。
int mp3BytesToMs(int bytes, {int bitrateKbps = kTtsMp3BitrateKbps}) {
  if (bytes <= 0 || bitrateKbps <= 0) return 0;
  return bytes * 8 ~/ bitrateKbps;
}

/// 整段都是 0x00（或空）——典型的「静音占位字节被当成正片落盘」。
bool allZeroBytes(List<int> data) {
  for (final byte in data) {
    if (byte != 0) return false;
  }
  return true;
}

/// 只在头部窗口里找第一个合法帧，用来判定「这堆字节到底是不是 mp3 音频」。
///
/// 完整清洗用 [extractMp3AudioFrames]；缓存有效性校验不想复制整个章节字节，用这个。
bool containsAudioFrame(List<int> data, {int scanLimit = 65536}) {
  final bytes = _asUint8List(data);
  final limit = scanLimit < bytes.length ? scanLimit : bytes.length;
  var i = _skipId3v2Tags(bytes, 0);
  while (i + 4 <= limit) {
    final size = _frameSize(bytes, i);
    if (size != null && i + size <= bytes.length) return true;
    i++;
  }
  return false;
}

/// 剔除容器头与非帧垃圾，返回只剩 MPEG 音频帧的字节序列（按序拼接）。
Uint8List extractMp3AudioFrames(List<int> data) {
  final bytes = _asUint8List(data);
  final out = BytesBuilder(copy: true);
  var i = _skipId3v2Tags(bytes, 0);
  var firstFrameSeen = false;
  while (i + 4 <= bytes.length) {
    final size = _frameSize(bytes, i);
    if (size == null) {
      // 垃圾字节：逐字节前移找下一个同步点。全零占位数据会在这里被整体走完而产出空结果。
      i++;
      continue;
    }
    if (i + size > bytes.length) {
      // 截断的尾帧：丢掉。继续逐字节扫描只会在帧体内撞上伪同步，产出更坏的字节。
      break;
    }
    if (!firstFrameSeen) {
      firstFrameSeen = true;
      if (_isXingFrame(bytes, i, size)) {
        i += size;
        continue;
      }
    }
    out.add(bytes.sublist(i, i + size));
    i += size;
    // 多张标签串在一起（上游偶发）：帧边界之后再来一次剔除。
    i = _skipId3v2Tags(bytes, i);
  }
  return out.toBytes();
}

Uint8List _asUint8List(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);

/// MPEG-1 Layer III 帧长表之外的公共校验：返回帧总长（含头），不是合法帧返回 null。
///
/// 只认 Layer III：Edge/ffmpeg 的输出都是 Layer III，别的 layer 的帧长公式不同，
/// 按 III 的公式误判会把音频切碎，所以宁可判为垃圾字节。
int? _frameSize(Uint8List b, int at) {
  if (at + 4 > b.length) return null;
  if (b[at] != 0xFF) return null;
  if ((b[at + 1] & 0xE0) != 0xE0) return null;
  final versionIndex =
      (b[at + 1] >> 3) & 0x03; // 3=MPEG1 2=MPEG2 0=MPEG2.5 1=保留
  if (versionIndex == 1) return null;
  final layerIndex = (b[at + 1] >> 1) & 0x03; // 1 = Layer III
  if (layerIndex != 1) return null;
  final bitrateIndex = (b[at + 2] >> 4) & 0x0F;
  final sampleIndex = (b[at + 2] >> 2) & 0x03;
  final padding = (b[at + 2] >> 1) & 0x01;
  if (bitrateIndex == 0 || bitrateIndex == 0x0F) return null; // 自由格式/非法
  if (sampleIndex == 3) return null;
  final bitrates = versionIndex == 3 ? _bitrateMpeg1L3 : _bitrateMpeg2L3;
  final samples = switch (versionIndex) {
    3 => _sampleMpeg1,
    2 => _sampleMpeg2,
    _ => _sampleMpeg25,
  };
  final bitrateKbps = bitrates[bitrateIndex];
  final sampleRate = samples[sampleIndex];
  if (bitrateKbps == 0 || sampleRate == 0) return null;
  final samplesPerFrame = versionIndex == 3 ? 1152 : 576;
  return samplesPerFrame ~/ 8 * bitrateKbps * 1000 ~/ sampleRate + padding;
}

/// 首帧是否为 Xing/Info 帧头（VBRT 元数据帧，不含音频）。
///
/// 标记位置取决于版本/声道/是否有 CRC，与其算表不如在帧首 4–64 字节的窗口里找
/// 这四个 ASCII 字符：误命中的代价只是丢一帧（48kbps 下约 24ms），远小于算错偏移。
bool _isXingFrame(Uint8List b, int at, int size) {
  final end = at + size;
  final window = at + 64 < end ? at + 64 : end;
  for (var i = at + 4; i + 4 <= window; i++) {
    if (_matchXingToken(b, i)) return true;
  }
  return false;
}

bool _matchXingToken(Uint8List b, int i) {
  const xing = <int>[0x58, 0x69, 0x6E, 0x67]; // 'Xing'
  const info = <int>[0x49, 0x6E, 0x66, 0x6F]; // 'Info'
  final a = b[i], bb = b[i + 1], c = b[i + 2], d = b[i + 3];
  return (a == xing[0] && bb == xing[1] && c == xing[2] && d == xing[3]) ||
      (a == info[0] && bb == info[1] && c == info[2] && d == info[3]);
}

/// 连续跳过任意张 ID3v2 标签，返回第一张标签之后的偏移。
///
/// 长度字段是 synchsafe（每字节低 7 位）；`flags` 里 footer 位（0x10）置位时页脚
/// **不计入**该长度，要另加 10 字节。即使这里算得不准也无所谓：主循环只接受
/// 合法帧，多余或少跳的字节会被当作垃圾逐字节跳过，不会污染音频。
int _skipId3v2Tags(Uint8List b, int from) {
  var i = from;
  while (i + 10 <= b.length &&
      b[i] == 0x49 &&
      b[i + 1] == 0x44 &&
      b[i + 2] == 0x33) {
    final flags = b[i + 5];
    final size =
        (b[i + 6] & 0x7F) << 21 |
        (b[i + 7] & 0x7F) << 14 |
        (b[i + 8] & 0x7F) << 7 |
        (b[i + 9] & 0x7F);
    if (size <= 0) break;
    var total = 10 + size;
    if (flags & 0x10 != 0) total += 10;
    i += total;
  }
  return i;
}

const List<int> _bitrateMpeg1L3 = <int>[
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  0,
];

const List<int> _bitrateMpeg2L3 = <int>[
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  0,
];

const List<int> _sampleMpeg1 = <int>[44100, 48000, 32000, 0];
const List<int> _sampleMpeg2 = <int>[22050, 24000, 16000, 0];
const List<int> _sampleMpeg25 = <int>[11025, 12000, 8000, 0];
