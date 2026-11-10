import 'cast_device_family.dart';
import 'cast_media_type.dart';
import 'cast_recipe.dart';
import 'didl.dart';

/// 兼容模式选路结果（M5-0/M5-3）。
///
/// - [direct]：URL 原样投给设备（直投）；
/// - [proxy]：经 [CastMediaProxy] 本机代理中转（防盗链头/清单改写）；
/// - [relay]：走 Go `castRelayStart` 本机转码（ffmpeg 管道，产物 HLS）——
///   执行体是现有中继，不新增转码器；改的只是「什么情况选它」。
enum CastRoute { direct, proxy, relay }

/// 兼容模式（本机转码后投屏）选路判定表（design §4.10 M10）。
///
/// 判定优先级（从上到下首个命中生效）：
/// 1. `viaRelay` → direct：URL 已是本机中继/镜像产物，不能再套一层转码
///    （加密分集与 resolvePlay 源的现状路径在调用方完成中继后置位）；
/// 2. `encrypted` → relay：加密分集强制中继（现状不变，解密只有 ffmpeg 能做）；
/// 3. `mode == always` → relay：用户显式要求转码（投不出去时的第一动作）；
/// 4. `mode == never` → 现状逻辑：防盗链头走代理，否则直投（用户显式关闭转码）；
/// 5. `auto`（能力感知）：
///    - MKV/FLV/WEBM → relay（国产电视多不支持这三类容器）；
///    - HEVC/AV1 编码提示 → relay（显式提示优先、内容嗅探其次，R1；
///      castrelay 已统一转 H.264）；
///    - HLS 且 Sink **非空且不含** HLS mime → relay（产物已是 .m3u8）；
///    - 其余 → 防盗链头走代理，否则直投（MP4/TS/HLS+支持 Sink/未知类型
///      全部维持现状，保证「现在能投的设备不回归」）。
///
/// Sink 判定用 [sinkHasHls]：**Sink 为空（预检失败/无条目）视为「能力未知」**，
/// 不触发转码——绝不因为预检拿不到就把所有 HLS 都送进 ffmpeg。
CastRoute resolveCastRoute({
  required CastTranscodeMode mode,
  CastMediaType? mediaType,
  Iterable<String> sinkMimes = const <String>[],
  bool encrypted = false,
  bool viaRelay = false,
  bool needsProxy = false,
  String codecHint = '',
  bool forceRelay = false,
}) {
  if (viaRelay) return CastRoute.direct;
  // 强制转码（11-10 档位降级）：HLS 会话被判定「接收端不认清单」后，重投必须
  // 落到中继产物上。旧实现只改 `_forcedRelayFormat='ts'`，选路仍可能因 Sink
  // 为空/媒体类型像 mp4 而返回 direct，于是把**源 CDN 地址**又投了一遍
  // （真机日志：SOAP fault / 电视端 STOPPED）。
  if (forceRelay) return CastRoute.relay;
  if (encrypted) return CastRoute.relay;
  switch (mode) {
    case CastTranscodeMode.always:
      return CastRoute.relay;
    case CastTranscodeMode.never:
      // 11-09 二期：设备明确宣告的 Sink 里没有任何 HLS 拼写时，「从不」会把
      // 这一集彻底锁死——直投 m3u8 对这类设备是「受理成功但永不取流」
      // （SHARP 央视频真机实证：PAUSED_PLAYBACK + TrackDuration=0 + 0 取流）。
      // 能播优先：覆盖 never 转本机中继，调用侧负责记时间线说明。
      if (sinkExplicitlyLacksHls(
        isHls: mediaType?.isHls ?? false,
        sinkMimes: sinkMimes,
      )) {
        return CastRoute.relay;
      }
      return needsProxy ? CastRoute.proxy : CastRoute.direct;
    case CastTranscodeMode.auto:
      break;
  }
  // ---- auto：能力感知选路 ----
  final mime = mediaType?.mime.toLowerCase() ?? '';
  if (_isRelayContainer(mime)) return CastRoute.relay;
  // 编码提示（R1）：显式（红果 stream.codec，调用方已按 mergeCodecHint 合并）
  // 优先；显式缺位时回落媒体类型携带的嗅探提示（ftyp brand / HLS CODECS），
  // 嗅探证据不因调用方漏合并而被丢掉。
  final codec = codecHint.trim().isNotEmpty
      ? codecHint
      : (mediaType?.codecHint ?? '');
  if (_isHighCodec(codec)) return CastRoute.relay;
  if (sinkExplicitlyLacksHls(
    isHls: mediaType?.isHls ?? false,
    sinkMimes: sinkMimes,
  )) {
    return CastRoute.relay;
  }
  return needsProxy ? CastRoute.proxy : CastRoute.direct;
}

/// 媒体是 HLS 且设备 Sink **明确**不含任何 HLS 拼写。
///
/// 「明确」= Sink 非空（预检拿到了设备自述的格式集合）且其中没有
/// `application/vnd.apple.mpegurl` / `application/x-mpegurl`。
/// Sink 为空表示能力未知，不算证据——绝不因为预检失败就把所有 HLS 送进 ffmpeg。
bool sinkExplicitlyLacksHls({
  required bool isHls,
  required Iterable<String> sinkMimes,
}) {
  if (!isHls) return false;
  final sink = sinkMimes.toList();
  if (sink.isEmpty) return false;
  return !sinkHasHls(sink);
}

/// Sink 清单是否宣告了 HLS mime（HLS 别名组两条拼写任一即可）。
bool sinkHasHls(Iterable<String> sinkMimes) {
  for (final entry in sinkMimes) {
    final mime = mimeOfSinkEntry(entry);
    if (mime == null) continue;
    if (_hlsMimes.contains(mime)) return true;
  }
  return false;
}

const Set<String> _hlsMimes = <String>{
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
};

/// 中继容器组：MKV / FLV / WEBM（含别名拼写）。
bool _isRelayContainer(String mime) =>
    mime == 'video/x-matroska' ||
    mime == 'video/x-mkv' ||
    mime == 'video/x-flv' ||
    mime == 'video/webm';

/// HEVC / AV1 编码提示（红果 VideoStream.codec 等来源；大小写不敏感，
/// h265/hevc 常混用）。H.264/空串不命中。
bool _isHighCodec(String codecHint) {
  final c = codecHint.trim().toLowerCase();
  return c == 'hevc' || c == 'h265' || c == 'h.265' || c == 'av1';
}

/// 编码提示合并口径（R1）：显式提示（红果 `stream.codec`）优先于内容
/// 嗅探（MP4 ftyp brand / HLS 主清单 CODECS）；两者都缺返回空串（不转码）。
/// 嗅探编码只影响选路，不改 DIDL/URL 形态语义。
String mergeCodecHint(String explicit, String? sniffed) {
  final e = explicit.trim();
  if (e.isNotEmpty) return e;
  return (sniffed ?? '').trim();
}

const Set<String> _tsMimes = <String>{
  'video/mp2t',
  'video/vnd.dlna.mpeg-tts',
};

/// 中继输出档位（R2，design §3.2）：按设备 Sink 能力选 Go castrelay 的
/// 产物形态。
///
/// - Sink 含 HLS mime → `hls`（现状，转码产物 .m3u8）；
/// - 不含 HLS 且含 TS 容器拼写（`video/mp2t` / `video/vnd.dlna.mpeg-tts`）
///   → `ts`（WMP 族：只认 TS 直流，HLS 清单黑屏）；
/// - Sink 缺失/未知/无命中 → [family] 默认（11-10：WMP 族给 `ts`），
///   未指定 family 时回落 `hls`（证据缺失回落现状，不回归）。
String relayFormatFor(Iterable<String> sinkMimes, {CastDeviceFamily? family}) {
  final mimes = <String>{};
  for (final entry in sinkMimes) {
    final mime = mimeOfSinkEntry(entry);
    if (mime != null) mimes.add(mime);
  }
  if (mimes.isEmpty) {
    return family == null ? 'hls' : relayFormatForFamily(family);
  }
  if (mimes.any(_hlsMimes.contains)) return 'hls';
  if (mimes.any(_tsMimes.contains)) return 'ts';
  return family == null ? 'hls' : relayFormatForFamily(family);
}

/// 中继产物的配方链升级（11-09 DIDL 真实性）：
///
/// - `ts` 档 → 默认 `standard` 升级为 `sinkEntry`：Sink 有同容器条目时照抄
///   设备自己的第 4 段（含其 PN/OP/FLAGS 拼写）；无条目时 sinkEntry 回落
///   `stream`（OP=00/CI=1，不可 seek）；
/// - `hls` 档 → 默认 `standard` 升级为 `stream`：转码流不可 seek、内容已转换，
///   不再谎报 `OP=01 + FLAGS`（go2tv 实测口径：只声明真实能力）。
///
/// 其余模板（bare/wildcard/withPn/op11）是显式旋钮，保持原样。
List<CastRecipe> upgradeChainForRelayProduct(
  List<CastRecipe> chain, {
  required bool ts,
}) =>
    <CastRecipe>[
      for (final r in chain)
        r.protocolInfoTemplate == DidlProtocolInfoTemplate.standard
            ? r.copyWith(
                protocolInfoTemplate: ts
                    ? DidlProtocolInfoTemplate.sinkEntry
                    : DidlProtocolInfoTemplate.stream)
            : r,
    ];

/// TS 档专用薄封装（保留旧签名：既有调用点/测试零改动）。
List<CastRecipe> upgradeChainForTsProduct(List<CastRecipe> chain) =>
    upgradeChainForRelayProduct(chain, ts: true);

