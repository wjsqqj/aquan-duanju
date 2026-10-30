/// Edge TTS 服务端的静态常量与「端点四元组」preset。
///
/// 真源：`D:\IdeaProjects\edge-tts`（Python 7.3.1）的 `constants.py` / `communicate.py`，
/// 逐条抄录口径见 `.trellis/tasks/10-30-listen-speech-engine-chain/research/edge-upstream-protocol.md`
/// §1。这里刻意把**只与服务端协议相关的常量**集中在一处，其它层（token/ssml/frames/stream）
/// 不再各自写死字符串 —— 端点正在漂移（说明书 §1.4），散落的字面量将来扫不干净。
///
/// 三条被说明书否定的写法，留在这里防止有人「顺手补回来」：
/// - **不发 `CV`**（v1 时代机制，7.3.1 全仓 grep 0 命中）；
/// - **不发 `Content-Length`**、**不发 `Sec-MS-Blob-*`**（上游同样 0 命中）；
/// - **`X-MSEdge-*` 不参与时钟纠偏**（上游只读标准 `Date`）。
library;

/// 上游 `TRUSTED_CLIENT_TOKEN`（constants.py:4）。它不是密钥，是公开的客户端标识。
const String kEdgeTrustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

/// token v2 被哈希消息的固定前缀（说明书 §2.2/§2.4，57 个 ASCII 字节）。
///
/// Python 把这段烘焙进 SHA-256 常量表（`drm.py:186-402`），不是算法分叉；
/// Dart 侧走标准 `crypto.sha256`，所以前缀必须以明文形式参与消息构造。
const String kEdgeGecPrefix =
    'Copyright (C) Microsoft Corporation. All rights reserved.';

/// Windows 文件时间纪元相对 Unix 纪元的秒数（`drm.py:18`）。可被 300 整除。
const int kEdgeWinEpochSeconds = 11644473600;

/// 1 秒 = 100 纳秒 tick 的个数（`constants.py:44`）。
const int kEdgeTicksPerSecond = 10000000;

/// token 时间向下对齐的粒度（秒）。上游 `ticks -= ticks % 300` = 5 分钟。
const int kEdgeAlignmentSeconds = 300;

/// 输出格式固定 48 kbps CBR（`constants.py:41-45`），字节↔时间换算的唯一依据。
const int kEdgeMp3BitrateBps = 48000;

/// 上游写死在 `speech.config` 里的输出格式串（`communicate.py:438`）。
const String kEdgeOutputFormat = 'audio-24khz-48kbitrate-mono-mp3';

/// 一个 tick 的分子/分母换算：`ms = tick ~/ kEdgeTickDivisor`（说明书 §5）。
const int kEdgeTickDivisor = 10000;

/// 单请求文本的 UTF-8 字节上限（`communicate.py:351`，是客户端常量不是服务端配额）。
const int kEdgeMaxChunkBytes = 4096;

/// 当前参照版本的 Chromium 版本串（`constants.py:11`）。
const String kEdgeChromiumFullVersion = '143.0.3650.75';

/// 主版本号（`constants.py:12`：`split('.', maxsplit=1)[0]`）。
const int kEdgeChromiumMajorVersion = 143;

/// 音色列表与合成端点的公共路径前缀（说明书 §1.4：两个 preset 的音色列表同源）。
const String kEdgeVoiceListPath =
    '/consumer/speech/synthesize/readaloud/voices/list';

/// 服务端**卡 User-Agent**（说明书 §8：HeadlessChrome UA 直接被 close 1006）。
const String kEdgeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    ' (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';

/// 上游 `Origin`（扩展 id，`constants.py:24`）。
const String kEdgeOrigin =
    'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

/// `BASE_HEADERS`（constants.py:14-20）。UA 单独列出，见 [edgeWssConnectHeaders] 的说明。
const Map<String, String> kEdgeBaseHeaders = <String, String>{
  'User-Agent': kEdgeUserAgent,
  'Accept-Encoding': 'gzip, deflate, br, zstd',
  'Accept-Language': 'en-US,en;q=0.9',
};

/// WSS 握手附加头（constants.py:21-26）。
const Map<String, String> kEdgeWssHeaders = <String, String>{
  'Pragma': 'no-cache',
  'Cache-Control': 'no-cache',
  'Origin': kEdgeOrigin,
  'Sec-WebSocket-Version': '13',
};

/// 音色列表请求附加头（constants.py:28-38）。`Authority` 的拼写照上游，不是笔误。
const Map<String, String> kEdgeVoiceHeaders = <String, String>{
  'Authority': 'speech.platform.bing.com',
  'Sec-CH-UA':
      '" Not;A Brand";v="99", "Microsoft Edge";v="143",'
      ' "Chromium";v="143"',
  'Sec-CH-UA-Mobile': '?0',
  'Accept': '*/*',
  'Sec-Fetch-Site': 'none',
  'Sec-Fetch-Mode': 'cors',
  'Sec-Fetch-Dest': 'empty',
};

/// 真正交给 `WebSocket.connect` 的 header。
///
/// 剔除两项：
/// - `User-Agent`：dart:io 对传入 header 走 `add` 而非 `set`（说明书 §10.2），
///   会和默认 UA 叠成两个 → UA 只能通过 `HttpClient()..userAgent=` 提供；
/// - `Sec-WebSocket-Version`：同理，dart:io 自己会写一个，重复发送只会造成两个版本号。
///
/// `Cookie` 不在这里（每次连接现造 muid，见 `generateEdgeMuid`）。
const Map<String, String> edgeWssConnectHeaders = <String, String>{
  'Pragma': 'no-cache',
  'Cache-Control': 'no-cache',
  'Origin': kEdgeOrigin,
  'Accept-Encoding': 'gzip, deflate, br, zstd',
  'Accept-Language': 'en-US,en;q=0.9',
};

/// 连接与单次收包的超时（说明书 §9.4：`sock_connect=10`、`sock_read=60`，总时长不限）。
const Duration kEdgeConnectTimeout = Duration(seconds: 10);
const Duration kEdgeReceiveTimeout = Duration(seconds: 60);

/// 没配置音色时的兜底（`listen.tts.voice` 为空 → 中文女声，design.md §8）。
const String kEdgeFallbackVoice = 'zh-CN-XiaoxiaoNeural';

/// token 方案。`v2` = CS64 + 标准 SHA-256 双段；`v1` 只在老端点见过（说明书 §9.5）。
enum EdgeTokenScheme { v1, v2 }

/// **端点四元组**：`{host, keyParamName, gecVersion, tokenScheme}`。
///
/// 上游 7.3.1 与本地另一份 live 实现（readest）在 host 与参数名上不一致，说明书 §1.4
/// 的结论是「不要把任一组合当永久真理」。因此端点必须是数据而不是散落的字符串，
/// 换端点时只改 preset（[edgeEndpointFallbackOrder]），不动算法与报文。
class EdgeEndpointPreset {
  const EdgeEndpointPreset({
    required this.name,
    required this.host,
    required this.wssPath,
    required this.keyParamName,
    required this.gecVersion,
    required this.tokenScheme,
    this.voiceHost = 'speech.platform.bing.com',
  });

  /// 人类可读标识，只进诊断信息（不进缓存键：键里是引擎 id）。
  final String name;

  /// WSS 主机名（不含 scheme）。
  final String host;

  /// WSS 路径（不含 query）。
  final String wssPath;

  /// 客户端标识的 query 参数名：`TrustedClientToken` 或 `Ocp-Apim-Subscription-Key`。
  final String keyParamName;

  /// `Sec-MS-GEC-Version` 的值，前缀 `2-` 表示 v2 token。
  final String gecVersion;

  final EdgeTokenScheme tokenScheme;

  /// 音色列表主机。说明书 §8 只证实了 bing 侧的音色列表 URL，
  /// 另一个 preset 也复用它，避免把未验证的 URL 当真理。
  final String voiceHost;

  /// `Sec-MS-GEC-Version` 的 `2-` 前缀即 v2 标记（说明书 §2 结论 3）。
  bool get isV2 => tokenScheme == EdgeTokenScheme.v2;

  /// 合成端点（不含 token 相关 query），由 `edge_stream` 补齐
  /// `ConnectionId` / `Sec-MS-GEC` / `Sec-MS-GEC-Version`。
  Uri get wssBaseUri => Uri(
    scheme: 'wss',
    host: host,
    path: wssPath,
    queryParameters: <String, String>{keyParamName: kEdgeTrustedClientToken},
  );

  /// 音色列表 URL（`VOICE_LIST`，参数名**全小写**，constants.py:7）。
  Uri get voiceListUri => Uri(
    scheme: 'https',
    host: voiceHost,
    path: kEdgeVoiceListPath,
    queryParameters: <String, String>{
      'trustedclienttoken': kEdgeTrustedClientToken,
    },
  );

  @override
  String toString() =>
      'EdgeEndpointPreset($name, $host, key=$keyParamName, $gecVersion, '
      'token=${tokenScheme.name})';
}

/// preset 表。**顺序就是 403 降级顺序**（说明书 §1.4：真源优先，
/// `api.msedgeservices.com` 作为 EU/ZA/PK 等地区已被 403 时的备选）。
const EdgeEndpointPreset kEdgeBingReadaloudPreset = EdgeEndpointPreset(
  name: 'bing-readaloud',
  host: 'speech.platform.bing.com',
  wssPath: '/consumer/speech/synthesize/readaloud/edge/v1',
  keyParamName: 'TrustedClientToken',
  gecVersion: '2-143.0.3650.75',
  tokenScheme: EdgeTokenScheme.v2,
);

/// 真源在 EU/ZA/PK 等地区被 403 时的备选（readest 用的就是这一组 host）。
const EdgeEndpointPreset kEdgeMsEdgeservicesTtsPreset = EdgeEndpointPreset(
  name: 'msedgeservices-tts',
  host: 'api.msedgeservices.com',
  wssPath: '/tts/cognitiveservices/websocket/v1',
  keyParamName: 'Ocp-Apim-Subscription-Key',
  gecVersion: '2-143.0.3650.75',
  tokenScheme: EdgeTokenScheme.v2,
);

const List<EdgeEndpointPreset> kEdgeEndpointPresets = <EdgeEndpointPreset>[
  kEdgeBingReadaloudPreset,
  kEdgeMsEdgeservicesTtsPreset,
];

/// 默认端点 = 真源那一条。
const EdgeEndpointPreset kEdgeDefaultPreset = kEdgeBingReadaloudPreset;

/// 从 [from] 开始的降级顺序（含自身）。
///
/// 本任务**不在一次请求里静默换 host**（403 只做一次时钟纠偏重试，见硬契约 10），
/// 这个函数的用途是：上层（步骤 7 的控制器 / 未来的设置项）在拿到 `authRejected` 后
/// 明确地换一个 preset 重建引擎，而不是让协议漂移变成看不见的行为。
List<EdgeEndpointPreset> edgeEndpointFallbackOrder(EdgeEndpointPreset from) {
  final index = kEdgeEndpointPresets.indexOf(from);
  if (index < 0) return kEdgeEndpointPresets;
  return kEdgeEndpointPresets.sublist(index);
}

/// 音色短名 → Azure 全名的正则（`data_classes.py:55`）。
final RegExp kEdgeVoiceShortNamePattern = RegExp(
  r'^([a-z]{2,})-([A-Z]{2,})-(.+Neural)$',
);

/// `prosody` 三项的合法形式（`data_classes.py:74-76`）：**必须带符号**，
/// 不接受 `x-high` 之类的相对描述。
final RegExp kEdgeRatePattern = RegExp(r'^[+-]\d+%$');
final RegExp kEdgePitchPattern = RegExp(r'^[+-]\d+Hz$');
