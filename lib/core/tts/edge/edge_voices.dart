/// 音色列表接口（说明书 §8）：GET 需要 DRM token + `muid` Cookie，字段有兜底。
///
/// 与合成通道共用 [HttpClientFactory]（代理与 UA 只能通过它生效）与 [DrmClock]
/// （403 时钟纠偏进程内共享）。`TtsVoice.id` 存 **ShortName**：短名才是
/// `azureVoiceName` 的输入，也是缓存键里那个稳定的音色标识。
library;

import 'dart:convert';
import 'dart:io';

import '../tts_models.dart';
import 'edge_constants.dart';
import 'edge_stream.dart';
import 'edge_token.dart';

/// 音色列表 URL：`VOICE_LIST` + `Sec-MS-GEC` + `Sec-MS-GEC-Version`（`voices.py:36-37`）。
Uri edgeVoiceListUri(EdgeEndpointPreset preset, {required String token}) =>
    preset.voiceListUri.replace(
      queryParameters: <String, String>{
        ...preset.voiceListUri.queryParameters,
        'Sec-MS-GEC': token,
        'Sec-MS-GEC-Version': preset.gecVersion,
      },
    );

/// 一条音色记录。`TtsVoice` 只装 id/display/locale（**既有模型不改**），
/// 其余上游字段留在这里，供未来的能力筛选（性别/场景）使用。
class EdgeVoiceRecord {
  const EdgeVoiceRecord({
    required this.voice,
    required this.gender,
    required this.contentCategories,
    required this.voicePersonalities,
    required this.locale,
    this.suggestedCodec = '',
    this.status = '',
  });

  final TtsVoice voice;
  final String gender;
  final List<String> contentCategories;
  final List<String> voicePersonalities;
  final String locale;
  final String suggestedCodec;
  final String status;
}

/// 解析响应数组。字段兜底与上游 `voices.py:45-54` 同口径：
/// 缺 `VoiceTag` / `ContentCategories` / `VoicePersonalities` 一律填空，
/// 缺 `ShortName` 的条目直接跳过（没短名就没法用）。
List<EdgeVoiceRecord> parseEdgeVoiceRecords(Object? decoded) {
  if (decoded is! List) return const <EdgeVoiceRecord>[];
  final out = <EdgeVoiceRecord>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final shortName = _str(item['ShortName']);
    if (shortName.isEmpty) continue;
    final localeText = _str(item['Locale']);
    final locale = localeText.isEmpty ? 'zh-CN' : localeText;
    final tag = item['VoiceTag'];
    out.add(
      EdgeVoiceRecord(
        voice: TtsVoice(
          id: shortName,
          displayName: _firstNotEmpty(<String>[
            _str(item['FriendlyName']),
            _str(item['Name']),
            shortName,
          ]),
          locale: locale,
        ),
        gender: _str(item['Gender']),
        contentCategories: _stringList(
          tag is Map ? tag['ContentCategories'] : null,
        ),
        voicePersonalities: _stringList(
          tag is Map ? tag['VoicePersonalities'] : null,
        ),
        locale: locale,
        suggestedCodec: _str(item['SuggestedCodec']),
        status: _str(item['Status']),
      ),
    );
  }
  return out;
}

/// 只要 `TtsVoice` 视图（引擎对外的形状）。
List<TtsVoice> parseEdgeVoices(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const <TtsVoice>[];
  }
  return parseEdgeVoiceRecords(decoded)
      .map((r) => r.voice)
      .toList(growable: false);
}

/// 走 HTTP 的音色列表：403 一次纠偏重试（与合成通道同一条规则）。
Future<List<TtsVoice>> edgeListVoices({
  required EdgeEndpointPreset preset,
  required HttpClientFactory httpClientFactory,
  required DrmClock clock,
  String proxy = '',
  DateTime Function()? now,
}) => edgeSkewGuarded(
  attempt: () => _listVoicesOnce(
    preset: preset,
    httpClientFactory: httpClientFactory,
    clock: clock,
    proxy: proxy,
    now: now,
  ),
  adjustClock: () => edgeProbeClockSkew(
    preset: preset,
    httpClientFactory: httpClientFactory,
    clock: clock,
    proxy: proxy,
    now: now,
  ),
);

Future<List<TtsVoice>> _listVoicesOnce({
  required EdgeEndpointPreset preset,
  required HttpClientFactory httpClientFactory,
  required DrmClock clock,
  required String proxy,
  DateTime Function()? now,
}) async {
  final client = httpClientFactory(
    EdgeHttpProfile(
      proxy: proxy,
      // `headers_with_muid`：Cookie 结尾的分号照上游（drm.py:609）。
      headers: <String, String>{
        ...kEdgeVoiceHeaders,
        ...kEdgeBaseHeaders,
        'Cookie': 'muid=${generateEdgeMuid()};',
      }..remove('User-Agent'),
    ),
  );
  try {
    final uri = edgeVoiceListUri(
      preset,
      token: generateSecMsGec(now: (now ?? DateTime.now)(), skew: clock.skew),
    );
    final response = await client.get(uri);
    if (response.statusCode == HttpStatus.forbidden) {
      throw EdgeConnectFailure(statusCode: HttpStatus.forbidden);
    }
    if (response.statusCode >= 400) {
      throw edgeFailureToException(
        EdgeConnectFailure(statusCode: response.statusCode),
      );
    }
    return parseEdgeVoices(response.body);
  } on EdgeConnectFailure {
    rethrow;
  } on TtsException {
    rethrow;
  } catch (e) {
    throw TtsException(
      TtsErrorCode.transport,
      message: 'edge 音色列表请求失败：${redactEdgeSecrets('$e')}',
      retryable: true,
    );
  } finally {
    client.close(force: true);
  }
}

String _str(Object? value) =>
    value is String ? value : (value?.toString() ?? '');

String _firstNotEmpty(List<String> values) {
  for (final value in values) {
    if (value.isNotEmpty) return value;
  }
  return '';
}

List<String> _stringList(Object? value) => value is List
    ? value.map((e) => '$e').toList(growable: false)
    : const <String>[];
