import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// UPnP SOAP 控制客户端（AVTransport / RenderingControl）。
///
/// 兼容经验（MiracastReceiver 服务端反推 + CineFlow 客户端实践）：
/// - `SOAPACTION` 头为 `"urn:<serviceType>#<Action>"`；
/// - 响应值解析要多模式兜底：标准响应元素、任意命名空间前缀、CDATA；
/// - 时间格式统一按 `H:MM:SS(.frac)` 解析，容错空串/非数；
/// - 每个 action 4s 超时，设备偶发 504 → 自动重试一次。
class SoapClient {
  SoapClient({http.Client? client, this.timeout = const Duration(seconds: 4)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// 执行一个 SOAP action，返回「返回值名 → 值」；失败抛 [SoapException]。
  Future<Map<String, String>> sendAction(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args,
  ) async {
    final body = buildEnvelope(serviceType, action, args);
    try {
      return await _send(controlUrl, serviceType, action, body);
    } on SoapException {
      // 设备偶发 504/超时：重试一次。
      return _send(controlUrl, serviceType, action, body);
    }
  }

  Future<Map<String, String>> _send(String controlUrl, String serviceType,
      String action, String body) async {
    final uri = Uri.tryParse(controlUrl);
    if (uri == null || !uri.hasScheme) {
      throw SoapException('非法 controlUrl: $controlUrl');
    }
    http.Response res;
    try {
      res = await _client
          .post(uri,
              headers: {
                'Content-Type': 'text/xml; charset="utf-8"',
                'SOAPACTION': '"$serviceType#$action"',
              },
              body: body)
          .timeout(timeout);
    } on TimeoutException {
      throw SoapException('$action 超时');
    } catch (e) {
      throw SoapException('$action 请求失败: $e');
    }
    // 部分设备对可选动作（Seek/音量）返回 401/501：调用方按 faultCode 处理。
    final fault = parseSoapFault(res.body);
    if (res.statusCode >= 400 || fault != null) {
      throw SoapException(
        '$action 失败 HTTP ${res.statusCode}',
        faultCode: fault?.$1,
        faultDescription: fault?.$2,
      );
    }
    final values = parseSoapResponse(res.body, action);
    return values;
  }

  void close() => _client.close();
}

class SoapException implements Exception {
  SoapException(this.message, {this.faultCode, this.faultDescription});
  final String message;
  final String? faultCode;
  final String? faultDescription;

  @override
  String toString() => faultCode == null
      ? message
      : '$message ($faultCode${faultDescription == null ? '' : ': $faultDescription'})';
}

/// SOAP 信封（参数顺序按 UPnP 服务描述；部分设备校验严格）。
String buildEnvelope(
    String serviceType, String action, Map<String, String> args) {
  final buffer = StringBuffer();
  buffer.write('<?xml version="1.0" encoding="utf-8"?>\n'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$serviceType">');
  args.forEach((name, value) {
    buffer.write('<$name>${_xmlEscape(value)}</$name>');
  });
  buffer.write('</u:$action></s:Body></s:Envelope>');
  return buffer.toString();
}

/// 解析 `<u:ActionResponse>` 返回值；多模式兜底：
/// 1) 标准响应元素子元素；2) 任意命名空间前缀下的同 localName 元素；
/// 3) 兜底正则 `<TagName>value</TagName>`（CDATA 自动被 xml 包展开）。
Map<String, String> parseSoapResponse(String body, String action) {
  final out = <String, String>{};
  XmlDocument? doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    doc = null;
  }
  if (doc != null) {
    XmlElement? response;
    for (final e in doc.rootElement.descendantElements) {
      if (e.name.local == '${action}Response') {
        response = e;
        break;
      }
    }
    if (response != null) {
      for (final child in response.childElements) {
        out[child.name.local] = child.innerText.trim();
      }
      if (out.isNotEmpty) return out;
    }
    // 没有响应元素（有的设备直接把返回值散在 Body 里）：抓常见返回字段。
    for (final e in doc.rootElement.descendantElements) {
      final local = e.name.local;
      if (_knownResultFields.contains(local) && !out.containsKey(local)) {
        out[local] = e.innerText.trim();
      }
    }
    if (out.isNotEmpty) return out;
  }
  // 正则兜底（响应可能是非法 XML）。
  for (final field in _knownResultFields) {
    final m = RegExp('<(?:[A-Za-z0-9]+:)?$field>(.*?)</(?:[A-Za-z0-9]+:)?$field>',
            dotAll: true)
        .firstMatch(body);
    if (m != null) out[field] = m.group(1)!.trim();
  }
  return out;
}

const Set<String> _knownResultFields = {
  'CurrentTransportState',
  'CurrentTransportStatus',
  'CurrentSpeed',
  'Track',
  'TrackDuration',
  'TrackMetaData',
  'TrackURI',
  'RelTime',
  'AbsTime',
  'CurrentVolume',
  'CurrentMute',
  'rcs:CurrentVolume',
};

/// (errorCode, errorDescription) 或 null。
(String?, String?)? parseSoapFault(String body) {
  XmlDocument? doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    final code = RegExp('<faultcode>(.*?)</faultcode>', dotAll: true)
        .firstMatch(body)
        ?.group(1);
    final desc = RegExp('<faultstring>(.*?)</faultstring>', dotAll: true)
        .firstMatch(body)
        ?.group(1);
    return code == null && desc == null ? null : (code, desc);
  }
  for (final e in [doc.rootElement, ...doc.rootElement.descendantElements]) {
    if (e.name.local == 'Fault' || e.name.local == 'fault') {
      String? code;
      String? desc;
      for (final c in e.descendantElements) {
        // SOAP 1.1 用 faultcode/faultstring，1.2 用 code/value 与 string；
        // UPnP 设备两者都有，取到即用。
        if (c.name.local == 'faultcode' || c.name.local == 'code') {
          code ??= c.innerText.trim();
        }
        if (c.name.local == 'faultstring' || c.name.local == 'string') {
          desc ??= c.innerText.trim();
        }
        // UPnP errorCode 数字也带上，方便识别 401/501/710。
        if (c.name.local == 'errorCode') {
          desc ??= 'errorCode ${c.innerText.trim()}';
        }
      }
      return (code, desc);
    }
  }
  return null;
}

/// `H:MM:SS(.frac)` / `MM:SS` → Duration；解析失败返回 null。
Duration? parseUpnpTime(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text == 'NOT_IMPLEMENTED') return null;
  final parts = text.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final h = parts.length == 3 ? int.tryParse(parts[0]) ?? 0 : 0;
  final m = int.tryParse(parts[parts.length - 2]);
  final secParts = parts.last.split('.');
  final s = int.tryParse(secParts.first);
  if (m == null || s == null) return null;
  var ms = 0;
  if (secParts.length == 2) {
    final frac = secParts[1].padRight(3, '0').substring(0, 3);
    ms = int.tryParse(frac) ?? 0;
  }
  return Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);
}

/// Duration → `H:MM:SS`。
String formatUpnpTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
