/// token v2（`Sec-MS-GEC`）生成：CS64 + 标准 SHA-256。
///
/// 全部纯函数（除随机 id 生成），可脱网单测。算法口径见
/// `research/edge-upstream-protocol.md` §2，golden 期望值由真源
/// `edge-tts/drm.py:_token_hash` 跑出来钉死（`research/token_golden_check.py`，
/// 另附 `research/cs64_equivalence_probe.py` 证明「readest 全消息朴素版 ≡
/// Python 烘焙前缀版」，所以本文件不需要翻译那 300 行位魔法）。
///
/// 三个不能改的事实：
/// 1. 被哈希的消息 = 57 字节前缀 + `ticks` + `TRUSTED_CLIENT_TOKEN`，总长 **107**；
/// 2. `ticks = (对齐到 300 秒的 unix 秒 + 11644473600) * 10000000`，**全程 int**
///    （Python 走 float 只是恰好没有舍入歧义，Dart 不跟）；
/// 3. token = `<16 位大写 hex CS64>-<64 位大写 hex SHA-256>`。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'edge_constants.dart';

const int _u32 = 0xFFFFFFFF;

/// 把 unix 秒向下对齐到 5 分钟（`ticks -= ticks % 300`）。
///
/// 负数（1970 年前的时间）按 Dart 的 `%` 语义会得到非零余数，业务上不会出现，
/// 这里不做额外处理，只保证 `[kEdgeAlignmentSeconds] 的倍数保持不变`。
int alignEdgeUnixSeconds(int seconds) =>
    seconds - seconds % kEdgeAlignmentSeconds;

/// 对齐后的 unix 秒 → Windows 文件时间（100 纳秒 tick）的十进制字符串。
///
/// 1.34e17 远小于 int64 上限 9.22e18，直接乘不会溢出（说明书 §10.7）。
String edgeFileTimeTicks(int alignedUnixSeconds) =>
    ((alignedUnixSeconds + kEdgeWinEpochSeconds) * kEdgeTicksPerSecond)
        .toString();

/// token 里被哈希的 suffix：`ticks + TRUSTED_CLIENT_TOKEN`（ASCII）。
String edgeTokenSuffix(int alignedUnixSeconds) =>
    '${edgeFileTimeTicks(alignedUnixSeconds)}$kEdgeTrustedClientToken';

/// 完整待哈希消息：57 字节前缀 + suffix。长度必须是 107（说明书 §2.2）。
Uint8List edgeGecMessage(String suffix) {
  final bytes = BytesBuilder(copy: false)
    ..add(ascii.encode(kEdgeGecPrefix))
    ..add(ascii.encode(suffix));
  return bytes.toBytes();
}

/// 标准 SHA-256，大写 hex（说明书 §2.4 结论：Python 的「改版」只是烘焙前缀，不是算法）。
String edgeSha256UpperHex(Uint8List message) =>
    sha256.convert(message).toString().toUpperCase();

/// CS64：token 的前 16 个 hex（说明书 §2.5，readest 全消息版）。
///
/// 32 位无符号语义统一 `& 0xFFFFFFFF`；两个 key 都要 `|= 1`（保证是奇数，
/// 乘法链才有足够的低位扰动）；输出按 `<II` 小端写 8 字节再大写。
String edgeCs64Hex(Uint8List message, Uint8List shaDigest) {
  final view = ByteData.sublistView(shaDigest);
  final keyA = (view.getUint32(0, Endian.little) | 1) & _u32;
  final keyB = (view.getUint32(4, Endian.little) | 1) & _u32;
  final words = _leWordsPaddedToEven(message);
  final terms = <int>[
    for (var i = 0; i < words.length; i++)
      (words[i] * (i.isEven ? keyA : keyB)) & _u32,
  ];
  final offsets = <int>[
    for (var i = 0; i < words.length; i++)
      (_rol16(words[i]) * (i.isEven ? 0xEF0569FB : 0xC31713DB)) & _u32,
  ];

  var swapAcc = 0;
  var swapLast = 0;
  var state = 0;
  var acc = 0;
  for (var i = 0; i + 1 < terms.length; i += 2) {
    final x = terms[i];
    final y = terms[i + 1];

    // 链 1：wordSwap —— 偶/奇下标各用一套乘数，last 只保留最后一对的结果。
    var t = _rol16((offsets[i] + x) & _u32);
    var q = (t * 0x76F50F34) & _u32;
    swapAcc += (_rol16(q) * 0xC3EFEA97 + q) & _u32;
    t = _rol16((offsets[i + 1] + y) & _u32);
    q = (t * 0x1881CE3C) & _u32;
    swapLast = (_rol16(q) * 0x35BD1EC9 + q) & _u32;
    swapAcc = (swapAcc + swapLast) & _u32;

    // 链 2：reversible —— state 滚动，acc 逐步累加。
    state = (state * keyA + x) & _u32;
    state = (_rol16(state) * 0xCF98B111) & _u32;
    state = (_rol16(state) * 0x87085B9F) & _u32;
    state = (_rol16(state) * 0x12CEB96D) & _u32;
    state = (_rol16(state) * 0x257E1D83) & _u32;
    acc += state;
    t = (state * keyB + y) & _u32;
    t = (_rol16(t) * 0xA27416F5) & _u32;
    t = (_rol16(t) * 0xD38396FF) & _u32;
    state = (_rol16((_rol16(t) * 0x7C932B89) & _u32) * 0xBFA49F69) & _u32;
    acc = (acc + state) & _u32;
  }

  final out = ByteData(8)
    ..setUint32(0, (swapLast ^ state) & _u32, Endian.little)
    ..setUint32(4, (swapAcc ^ acc) & _u32, Endian.little);
  return _hexUpper(out.buffer.asUint8List());
}

/// 生成 `Sec-MS-GEC`。注入 [now] 后完全确定（无随机），因此可以被 golden 单测钉死。
///
/// [skew] 是时钟纠偏量（[DrmClock] 维护）：上游在取时间时叠加，这里同样先叠加再对齐，
/// 顺序与 `drm.py:476-481` 一致。
String generateSecMsGec({DateTime? now, Duration skew = Duration.zero}) {
  final seconds =
      (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch ~/ 1000 +
      skew.inSeconds;
  final suffix = edgeTokenSuffix(alignEdgeUnixSeconds(seconds));
  final message = edgeGecMessage(suffix);
  final digest = sha256.convert(message).bytes;
  final cs64 = edgeCs64Hex(
    Uint8List.fromList(message),
    Uint8List.fromList(digest),
  );
  return '$cs64-${_hexUpper(Uint8List.fromList(digest))}';
}

/// `ConnectionId` / `X-RequestId`：每次新造的小写 32 hex（`connect_id()`，
/// `communicate.py:102-109`）。edge_dart 用大写，真源是小写。
String newEdgeRequestId() => _randomHex(16, upper: false);

/// `muid` Cookie 值：32 位随机**大写** hex（`drm.py:587-594`）。
String generateEdgeMuid() => _randomHex(16, upper: true);

/// token/key/muid 这类长 hex 的**可写日志形式**：只留哈希前缀与长度，绝不落全值。
///
/// 硬契约 10：异常 message 与日志不得出现全值。`sha256` 的前 8 位足够把同一次失败
/// 与某条 token 关联起来，同时不可逆推 token。
String edgeSecretFingerprint(String secret) => secret.isEmpty
    ? '<empty>'
    : '${edgeSha256UpperHex(Uint8List.fromList(ascii.encode(secret))).substring(0, 8)}'
          '/len=${secret.length}';

/// 时钟纠偏状态（说明书 §9.2）。
///
/// 上游 `clock_skew_seconds` 是**类级全局**，进程内共享：一次 403 纠偏后所有后续请求
/// 都受益。这里保留同样的语义（[DrmClock.shared]），但允许注入独立实例给单测。
class DrmClock {
  DrmClock({this.skew = Duration.zero});

  /// 进程内共享实例：引擎默认使用它。
  static final DrmClock shared = DrmClock();

  /// 当前纠偏量（加到本地 unix 秒上）。公有可写：测试要能把它摆到指定偏移。
  Duration skew;

  /// 按响应 `Date` 头纠偏（**累加**语义与上游一致）。
  ///
  /// 上游写的是 `skew += server - (local + skew)`，代数上等于 `server - local`：
  /// 即纠偏是「补齐到服务端时间」，重复调用不会把同一个偏差放大两次。
  /// 返回 false 表示头缺失/解析失败（上游对应 `SkewAdjustmentError`）。
  bool adjustFromHttpDate(String? dateHeader, {DateTime? localNow}) {
    final server = parseHttpDate(dateHeader);
    if (server == null) return false;
    final local = localNow ?? DateTime.now().toUtc();
    final deltaSeconds = server.difference(local).inSeconds - skew.inSeconds;
    skew += Duration(seconds: deltaSeconds);
    return true;
  }

  void reset() => skew = Duration.zero;
}

/// RFC 1123 / RFC 2616 的 `Date` 头解析（`drm.py:520-539` 的等价实现）。
///
/// 不用 `intl` 依赖：格式固定 `Wdy, DD Mon YYYY HH:MM:SS GMT`，手写解析反而没有
/// locale 歧义（月份缩写必须是英文）。解不出来返回 null（调用方按纠偏失败处理）。
DateTime? parseHttpDate(String? header) {
  final value = header?.trim();
  if (value == null || value.isEmpty) return null;
  final comma = value.indexOf(',');
  final body = comma < 0 ? value : value.substring(comma + 1).trim();
  final parts = body.split(RegExp(r'\s+'));
  if (parts.length < 5) return null;
  final day = int.tryParse(parts[0]);
  final month = _httpMonths[parts[1].toUpperCase()];
  final year = int.tryParse(parts[2]);
  final clock = parts[3].split(':');
  if (day == null || month == null || year == null || clock.length < 3) {
    return null;
  }
  final hour = int.tryParse(clock[0]);
  final minute = int.tryParse(clock[1]);
  final second = int.tryParse(clock[2]);
  if (hour == null || minute == null || second == null) return null;
  // 时区符号缺失（`GMT`/`UTC`/数字偏移都可能出现在中间件里）一律按 UTC 处理：
  // 上游也是把无 tzinfo 的结果 replace 成 utc。
  final zone = parts.length > 4 ? parts[4].toUpperCase() : 'GMT';
  var offsetSeconds = 0;
  final zoneMatch = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(zone);
  if (zoneMatch != null) {
    offsetSeconds =
        int.parse(zoneMatch.group(2)!) * 3600 +
        int.parse(zoneMatch.group(3)!) * 60;
    if (zoneMatch.group(1) == '-') offsetSeconds = -offsetSeconds;
  }
  final utc = DateTime.utc(year, month, day, hour, minute, second);
  return offsetSeconds == 0
      ? utc
      : utc.subtract(Duration(seconds: offsetSeconds));
}

const Map<String, int> _httpMonths = <String, int>{
  'JAN': 1,
  'FEB': 2,
  'MAR': 3,
  'APR': 4,
  'MAY': 5,
  'JUN': 6,
  'JUL': 7,
  'AUG': 8,
  'SEP': 9,
  'OCT': 10,
  'NOV': 11,
  'DEC': 12,
};

/// 小端 32 位字序列，0 补齐到 4 字节再补到**偶数个**字（`drm.py:161-169`）。
///
/// 偶数是下游两两配对（x/y）的前提；107 字节 → 108 → 27 字 → 补成 28 字，
/// 与 Python 的「14 个烘焙前缀字 + 14 个 suffix 字」字数一致（说明书 §2.5 校验锚点）。
List<int> _leWordsPaddedToEven(Uint8List data) {
  final pad = (-data.length) % 4;
  final padded = Uint8List(data.length + pad)..setRange(0, data.length, data);
  final view = ByteData.sublistView(padded);
  final words = <int>[
    for (var i = 0; i + 4 <= padded.length; i += 4)
      view.getUint32(i, Endian.little),
  ];
  if (words.length.isOdd) words.add(0);
  return words;
}

/// 32 位循环左移 16（`drm.py:155-158`）。
int _rol16(int value) {
  final v = value & _u32;
  return ((v << 16) | (v >>> 16)) & _u32;
}

String _hexUpper(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return sb.toString();
}

String _randomHex(int byteLength, {required bool upper}) {
  final random = Random.secure();
  final bytes = Uint8List(byteLength);
  for (var i = 0; i < byteLength; i++) {
    bytes[i] = random.nextInt(256);
  }
  final hex = _hexUpper(bytes);
  return upper ? hex : hex.toLowerCase();
}
