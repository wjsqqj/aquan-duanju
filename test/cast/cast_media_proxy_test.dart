import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_proxy.dart';

void main() {
  late HttpServer upstream;
  late CastMediaProxy proxy;
  // path → {referer, range}（HttpHeaders 无 keys 迭代，按需捕获断言所需头）。
  final upstreamHeaders = <String, Map<String, String?>>{};

  setUp(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      upstreamHeaders[req.uri.path] = {
        'referer': req.headers.value('referer'),
        'range': req.headers.value('range'),
      };
      final range = req.headers.value('range');
      req.response.headers.contentType =
          ContentType('application', 'octet-stream');
      final body = utf8.encode('0123456789ABCDEF');
      if (req.uri.path == '/list.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write('#EXTM3U\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="/secret.key",IV=0x1\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
            '/720p/list.m3u8\n'
            '#EXTINF:4.0,\n'
            '/seg1.ts\n');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/720p/list.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write('#EXTM3U\n#EXTINF:4.0,\n/720p/seg-1.ts\n');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/sub.srt') {
        req.response.headers.contentType =
            ContentType('application', 'x-subrip', charset: 'utf-8');
        req.response.write('1\n00:00:01,000 --> 00:00:03,000\n你好世界\n');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/forbidden-without-header') {
        if (upstreamHeaders[req.uri.path]?['referer'] == null) {
          req.response.statusCode = 403;
          await req.response.close();
          return;
        }
      }
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(range)!;
        final start = int.parse(m.group(1)!);
        final end = m.group(2) == null ? body.length - 1 : int.parse(m.group(2)!);
        req.response.statusCode = 206;
        req.response.headers.set('Content-Range',
            'bytes $start-$end/${body.length}');
        req.response.add(body.sublist(start, end + 1));
        await req.response.close();
        return;
      }
      req.response.add(body);
      await req.response.close();
    });
    proxy = CastMediaProxy(
      hostOverride: '192.168.1.5',
      client: HttpClient()..connectionTimeout = const Duration(seconds: 2),
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.close();
  });

  /// 代理登记返回的是 hostOverride 假 IP；本机客户端请求走回环地址。
  Uri localOf(String proxied) =>
      Uri.parse(proxied.replaceFirst('http://192.168.1.5:', 'http://127.0.0.1:'));

  test('直链代理：注入头、透传字节、Range 206', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/forbidden-without-header',
      headers: {'Referer': 'http://origin/'},
    );
    expect(proxied, isNotNull);

    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.statusCode, 200,
        reason: '上游没收到 Referer 会回 403；200 说明头已注入');
    final text = await res.transform(utf8.decoder).join();
    expect(text, '0123456789ABCDEF');
    upstreamHeaders.clear();

    // Range 透传：206 + Content-Range + 区间字节。
    final req = await client.getUrl(localOf(proxied));
    req.headers.set('Range', 'bytes=2-5');
    final ranged = await req.close();
    expect(ranged.statusCode, 206);
    expect(ranged.headers.value('content-range'), 'bytes 2-5/16');
    final chunk = await ranged.transform(utf8.decoder).join();
    expect(chunk, '2345');
    expect(upstreamHeaders['/forbidden-without-header']?['range'], 'bytes=2-5');
    client.close();
  });

  test('HLS 清单改写：变体/分片/KEY 全部代理化，且可二次穿透', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
      headers: {'Referer': 'http://origin/'},
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    final playlist = await res.transform(utf8.decoder).join();
    expect(playlist, isNot(contains('/secret.key')),
        reason: 'KEY URI 必须被改写');
    expect(playlist, contains('#EXT-X-KEY:METHOD=AES-128,URI="http://192.168.1.5:'));
    expect(playlist, contains('URI="http://192.168.1.5:'), reason: '属性 URI 代理化');
    expect(playlist.contains('#EXTINF:4.0,\nhttp://192.168.1.5:'), isTrue,
        reason: '裸分片行代理化');

    // 从改写后的清单里取一个代理 URL 再请求 → 二级清单再改写。
    final childMatch =
        RegExp(r'#EXT-X-STREAM-INF:BANDWIDTH=1000000\n(\S+)').firstMatch(playlist);
    final variant = await client
        .getUrl(localOf(childMatch!.group(1)!))
        .then((r) => r.close());
    final variantText = await variant.transform(utf8.decoder).join();
    expect(variantText.contains('http://192.168.1.5:'), isTrue,
        reason: '嵌套清单同样被改写');
    client.close();
  });

  test('SRT 字幕：拉取转 VTT 伺服（text/vtt + WEBVTT 头 + 毫秒点号）', () async {
    final proxied = await proxy.registerSubtitle(
      'http://127.0.0.1:${upstream.port}/sub.srt',
      headers: {'Referer': 'http://origin/'},
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.headers.contentType?.mimeType, 'text/vtt');
    final text = await res.transform(utf8.decoder).join();
    expect(text.startsWith('WEBVTT'), isTrue);
    expect(text.contains('00:00:01.000 --> 00:00:03.000'), isTrue);
    expect(text.contains('你好世界'), isTrue);
    client.close();
  });

  test('响应不含安全头（x-frame-options 等会让部分渲染器拒播）', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.headers.value('x-frame-options'), isNull);
    expect(res.headers.value('x-content-type-options'), isNull);
    expect(res.headers.value('x-xss-protection'), isNull);
    client.close();
  });

  test('未登记 token → 404', () async {
    final client = HttpClient();
    final res = await client
        .getUrl(Uri.parse('http://127.0.0.1:${proxy.port}/p/unknown'))
        .then((r) => r.close());
    expect(res.statusCode, 404);
    client.close();
  });
}
