/// 声明式 HTTP TTS 源：把「第三方语音合成接口」描述成一份 JSON，不写代码。
///
/// 为什么先做声明式而不是 JS 脚本：工程已有 `spider_js_runtime`（书源用），但脚本层
/// 要处理沙箱、超时、任意返回类型；而绝大多数自建 TTS（GPT-SoVITS、tts-server、
/// OpenAI 兼容网关）只需要「GET/POST 一个 URL，拿回音频或一个 JSON 字段」。
/// 先把这条 90% 的路打通并测透，脚本层留给后续增量（见 PRD Out of Scope）。
library;

import 'dart:convert';

import '../speech_engine.dart';
import '../tts_models.dart';

/// `listen.tts.engine` 取这个值时走第三方 HTTP 源（否则回 Edge）。
const String kHttpTtsEngineId = 'http';

/// 响应怎么取音频。
enum HttpTtsResponseMode {
  /// 响应体就是音频字节（`audio/mpeg` 等）。
  audio,

  /// 响应是 JSON，[HttpTtsSource.audioField] 指向一个**音频直链**，需再请求一次。
  jsonUrl,

  /// 响应是 JSON，[HttpTtsSource.audioField] 指向 **base64 音频**。
  jsonBase64,
}

/// body 模板里 `{text}` / `{voice}` 的转义方式。
///
/// 默认 `json`：绝大多数自建 TTS 的 body 就是 JSON。
/// Azure 这类要发 **SSML(XML)** 的服务必须用 `xml` —— 用 JSON 转义写进 XML，
/// `&`/`<` 会直接把请求变成非法 XML，服务端只回 400，错误信息还看不出是转义问题。
enum HttpTtsBodyEscape {
  json,
  xml,
  none,
}

/// 一份 HTTP TTS 源配置。
///
/// 模板占位符只有两个：`{text}` 与 `{voice}`。
/// - URL 里：自动 percent-encode；
/// - body 里：自动 JSON 转义（**不带外层引号**，引号由模板自己写）。
///
/// **故意不支持 `{speed}`**：倍速由播放器 `setRate` 实现，时间点存媒体时间轴；
/// 若让服务端按速度合成，缓存键就得含倍速（违反 `listen-tts-contract` 的硬约束）。
class HttpTtsSource {
  const HttpTtsSource({
    required this.id,
    required this.name,
    required this.urlTemplate,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.bodyTemplate = '',
    this.bodyEscape = HttpTtsBodyEscape.json,
    this.mode = HttpTtsResponseMode.audio,
    this.audioField = '',
    this.voices = const <TtsVoice>[],
    this.bitrateKbps = kTtsMp3BitrateKbps,
  });

  /// 源标识：进缓存键（`http:<id>`），改配置要换 id 否则会命中旧产物。
  final String id;
  final String name;

  /// 必须包含 `{text}`；通常也含 `{voice}`。
  final String urlTemplate;

  /// `GET` / `POST`（大小写不敏感，统一按大写处理）。
  final String method;

  final Map<String, String> headers;

  /// POST 的请求体模板（JSON / SSML）。`{text}` 按 [bodyEscape] 转义后填入。
  final String bodyTemplate;

  /// body 模板的转义方式（见 [HttpTtsBodyEscape]）。
  final HttpTtsBodyEscape bodyEscape;

  final HttpTtsResponseMode mode;

  /// [HttpTtsResponseMode.jsonUrl] / [HttpTtsResponseMode.jsonBase64] 时的字段名
  /// （支持一层点号路径，如 `data.audio`）。
  final String audioField;

  final List<TtsVoice> voices;

  /// 产物按 CBR 估算时长用的码率；非 mp3 源不要用本引擎（见 [supportsMp3]）。
  final int bitrateKbps;

  bool get isPost => method.toUpperCase() == 'POST';

  /// 本引擎只按 mp3 帧切容器与算时长：源头必须给 mp3。
  bool get supportsMp3 => true;

  /// 解析用户粘贴的 JSON；任何不合法都返回 `null`（设置页据此提示，不抛）。
  static HttpTtsSource? tryParse(Object? raw) {
    Object? data = raw;
    if (raw is String) {
      try {
        data = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    if (data is! Map) return null;
    final map = data.cast<String, dynamic>();

    final id = (map['id'] as String?)?.trim() ?? '';
    final url = (map['url'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    if (url.isEmpty || !url.startsWith('http://') && !url.startsWith('https://')) {
      return null;
    }
    // `{text}` 必须在 URL 或 body 里出现：POST + SSML 类的服务（Azure）文本全在 body，
    // URL 只是端点。两者都没有 => 根本发不出内容，视为配置错误。
    final rawBody = (map['body'] as String?) ?? '';
    if (!url.contains('{text}') && !rawBody.contains('{text}')) return null;

    final modeName = (map['mode'] as String?)?.trim() ?? 'audio';
    final mode = switch (modeName) {
      'audio' => HttpTtsResponseMode.audio,
      'jsonUrl' => HttpTtsResponseMode.jsonUrl,
      'jsonBase64' => HttpTtsResponseMode.jsonBase64,
      _ => null,
    };
    if (mode == null) return null;

    final audioField = (map['audioField'] as String?)?.trim() ?? '';
    if (mode != HttpTtsResponseMode.audio && audioField.isEmpty) return null;

    final method = ((map['method'] as String?)?.trim() ?? 'GET').toUpperCase();
    if (method != 'GET' && method != 'POST') return null;

    final headers = <String, String>{};
    final rawHeaders = map['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k is String && v != null) headers[k] = v.toString();
      });
    }

    final voices = <TtsVoice>[];
    final rawVoices = map['voices'];
    if (rawVoices is List) {
      for (final v in rawVoices) {
        if (v is String && v.isNotEmpty) {
          voices.add(TtsVoice(id: v));
        } else if (v is Map && v['id'] is String) {
          voices.add(TtsVoice(
            id: v['id'] as String,
            displayName: (v['name'] as String?) ?? '',
          ));
        }
      }
    }

    final name = (map['name'] as String?)?.trim() ?? id;
    final bitrate = (map['bitrateKbps'] as num?)?.toInt() ?? kTtsMp3BitrateKbps;
    final bodyEscape = switch ((map['bodyEscape'] as String?)?.trim()) {
      'xml' => HttpTtsBodyEscape.xml,
      'none' => HttpTtsBodyEscape.none,
      _ => HttpTtsBodyEscape.json,
    };

    return HttpTtsSource(
      id: id,
      name: name,
      urlTemplate: url,
      method: method,
      headers: headers,
      bodyTemplate: rawBody,
      bodyEscape: bodyEscape,
      mode: mode,
      audioField: audioField,
      voices: voices,
      bitrateKbps: bitrate > 0 ? bitrate : kTtsMp3BitrateKbps,
    );
  }

  /// 生成请求 URL（`{text}`/`{voice}` 已 percent-encode；其余字符原样保留）。
  Uri buildUri({required String text, required String voice}) {
    final rendered = urlTemplate
        .replaceAll('{text}', Uri.encodeComponent(text))
        .replaceAll('{voice}', Uri.encodeComponent(voice));
    return Uri.parse(rendered);
  }

  /// POST 请求体：`{text}`/`{voice}` 按 [bodyEscape] 转义（不带外层引号，模板自带）。
  String buildBody({required String text, required String voice}) {
    if (bodyTemplate.isEmpty) return '';
    return bodyTemplate
        .replaceAll('{text}', _escape(text))
        .replaceAll('{voice}', _escape(voice));
  }

  String _escape(String value) => switch (bodyEscape) {
    HttpTtsBodyEscape.json => _jsonEscape(value),
    HttpTtsBodyEscape.xml => _xmlEscape(value),
    HttpTtsBodyEscape.none => value,
  };

  static String _jsonEscape(String value) {
    final encoded = jsonEncode(value);
    // 去掉 jsonEncode 加的两端引号：模板自己决定要不要引号。
    return encoded.substring(1, encoded.length - 1);
  }

  /// XML 文本节点/属性值的转义。`&` 必须**先**转，否则会把后续替换出的 `&amp;` 再转一次。
  static String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// 回写 JSON（与 [tryParse] 互逆）：源列表要存多份就必须能往返。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'url': urlTemplate,
    'method': method,
    if (headers.isNotEmpty) 'headers': headers,
    if (bodyTemplate.isNotEmpty) 'body': bodyTemplate,
    if (bodyEscape != HttpTtsBodyEscape.json) 'bodyEscape': bodyEscape.name,
    'mode': mode.name,
    if (audioField.isNotEmpty) 'audioField': audioField,
    if (voices.isNotEmpty)
      'voices': voices
          .map(
            (v) => v.displayName.isEmpty
                ? v.id
                : <String, dynamic>{'id': v.id, 'name': v.displayName},
          )
          .toList(),
    if (bitrateKbps != kTtsMp3BitrateKbps) 'bitrateKbps': bitrateKbps,
  };
}
