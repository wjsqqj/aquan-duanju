import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'hls_adfilter.dart';

/// HLS 去广告本地代理：回环 HTTP 服务，把上游 m3u8 重写为去广告清单，
/// 分片/密钥经代理透传（自动注入源级 Referer/UA 头）。
///
/// URL 形态：`http://127.0.0.1:<port>/mp/<token>?u=<base64url>&h=<base64url>`。
/// 生命周期：懒启动 + 引用计数，归零 5 分钟后回收；仅绑 127.0.0.1。
class MediaProxy {
  MediaProxy._();

  static final MediaProxy instance = MediaProxy._();

  HttpServer? _server;
  String? _token;
  int _refs = 0;
  Timer? _idleTimer;

  static const idleTimeout = Duration(minutes: 5);

  /// 获取代理基址（内部已含 token）；引用计数 +1。
  Future<String> acquire() async {
    _idleTimer?.cancel();
    _refs++;
    var server = _server;
    if (server != null) {
      return 'http://127.0.0.1:${server.port}/mp/$_token';
    }
    _token = _randomToken();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        await _handle(req);
      } catch (_) {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      }
    });
    _server = server;
    return 'http://127.0.0.1:${server.port}/mp/$_token';
  }

  /// 引用计数 -1；归零后空闲回收。
  Future<void> release() async {
    _refs = (_refs - 1).clamp(0, 1 << 30);
    if (_refs == 0) {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleTimeout, () => _stop());
    }
  }

  Future<void> _stop() async {
    await _server?.close(force: true);
    _server = null;
    _token = null;
  }

  /// 把一个上游媒体 URL 包成代理 URL（headers 随请求携带，base64url JSON）。
  String wrap(String upstreamUrl, {Map<String, String> headers = const {}}) {
    final base = 'http://127.0.0.1:${_server!.port}/mp/$_token';
    final u = base64Url.encode(utf8.encode(upstreamUrl)).replaceAll('=', '');
    final h = headers.isEmpty
        ? ''
        : base64Url.encode(utf8.encode(jsonEncode(headers))).replaceAll('=', '');
    return '$base?u=$u${h.isEmpty ? '' : '&h=$h'}';
  }

  Future<void> _handle(HttpRequest req) async {
    final token = _token;
    if (token == null ||
        !req.uri.path.startsWith('/mp/$token') ||
        req.uri.queryParameters['u'] == null) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final upstream = _decodeB64(req.uri.queryParameters['u']!);
    final headers = _decodeHeaders(req.uri.queryParameters['h']);
    final client = http.Client();
    try {
      final upstreamUri = Uri.parse(upstream);
      final res = await client.get(upstreamUri, headers: {
        'Range': req.headers.value('Range') ?? '',
        ...headers,
      }..remove(''));
      final contentType = res.headers['content-type'] ?? '';
      final looksLikeManifest = upstream.toLowerCase().contains('.m3u8') ||
          contentType.contains('mpegurl');
      if (looksLikeManifest) {
        final text = utf8.decode(res.bodyBytes, allowMalformed: true);
        final rewritten = HlsAdFilter.rewriteManifest(text, upstreamUri,
            (abs) => wrap(abs, headers: headers));
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write(rewritten);
        await req.response.close();
        return;
      }
      // 分片/密钥：流式透传（Range 已透传给上游）。
      req.response.statusCode = res.statusCode;
      final resType = res.headers['content-type'];
      if (resType != null) req.response.headers.set('content-type', resType);
      final contentRange = res.headers['content-range'];
      if (contentRange != null) {
        req.response.headers.set('content-range', contentRange);
      }
      req.response.headers.set('accept-ranges', 'bytes');
      req.response.add(res.bodyBytes);
      await req.response.close();
    } finally {
      client.close();
    }
  }

  static String _decodeB64(String input) =>
      utf8.decode(base64Url.decode(base64Url.normalize(input)));

  static Map<String, String> _decodeHeaders(String? b64) {
    if (b64 == null || b64.isEmpty) return const {};
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(b64))));
      if (json is Map) {
        return json.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return const {};
  }

  static String _randomToken() {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 't$t${t.hashCode.abs().toRadixString(36)}';
  }
}
