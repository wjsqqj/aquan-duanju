import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:aquan_duanju/core/sources/hls_adfilter.dart';
import 'dart:io';

import 'package:aquan_duanju/core/sources/media_proxy.dart';

/// 绕过系统代理的直连客户端（代理/中继地址是回环语义，走 clash 会 502）。
http.Client directClient() {
  final inner = HttpClient()..findProxy = (_) => 'DIRECT';
  return IOClient(inner);
}

void main() {
  group('HlsAdFilter 纯函数', () {
    const mediaManifest = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
http://cdn/video/seg1.ts
#EXT-X-DISCONTINUITY
#EXTINF:6.0,
http://cdn/video/ad/seg2.ts
#EXTINF:6.0,
http://cdn/video/sponsor/seg3.ts
#EXTINF:6.0,
http://cdn/video/seg4.ts
''';

    test('去广告：命中关键字分片连同 EXTINF 剔除，DISCONTINUITY 剥除，URI 重写', () {
      final out = HlsAdFilter.rewriteManifest(
          mediaManifest, Uri.parse('http://up/index.m3u8'),
          (abs) => 'PROXY|$abs');
      expect(out, isNot(contains('ad/seg2')));
      expect(out, isNot(contains('sponsor/seg3')));
      expect(out, isNot(contains('#EXT-X-DISCONTINUITY')));
      expect(out, contains('PROXY|http://cdn/video/seg1.ts'));
      expect(out, contains('PROXY|http://cdn/video/seg4.ts'));
      // EXTINF 与 URI 成对：4 条 EXTINF → 2 条。
      expect(RegExp('#EXTINF').allMatches(out).length, 2);
    });

    test('安全阈值：广告占比超 50% 回退原文（URI 仍重写）', () {
      const mostlyAds = '''
#EXTM3U
#EXTINF:6.0,
http://cdn/ads/1.ts
#EXTINF:6.0,
http://cdn/ads/2.ts
#EXTINF:6.0,
http://cdn/video/ok.ts
''';
      final out = HlsAdFilter.rewriteManifest(
          mostlyAds, Uri.parse('http://up/index.m3u8'),
          (abs) => 'PROXY|$abs');
      expect(out, contains('http://cdn/ads/1.ts'), reason: '误杀保护：回退原文');
      expect(out, contains('PROXY|http://cdn/video/ok.ts'),
          reason: '回退路径 URI 仍要重写');
    });

    test('主清单只重写 URI 不去广告', () {
      const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000
http://cdn/video/720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000000
http://cdn/video/1080p.m3u8
''';
      final out = HlsAdFilter.rewriteManifest(
          master, Uri.parse('http://up/master.m3u8'),
          (abs) => 'PROXY|$abs');
      expect(out, contains('PROXY|http://cdn/video/720p.m3u8'));
      expect(out, contains('PROXY|http://cdn/video/1080p.m3u8'));
    });

    test('相对地址按 baseUri 转绝对', () {
      const rel = '#EXTM3U\n#EXTINF:6.0,\nvideo/seg1.ts\n';
      final out = HlsAdFilter.rewriteManifest(
          rel, Uri.parse('http://up/hls/index.m3u8'),
          (abs) => abs);
      expect(out, contains('http://up/hls/video/seg1.ts'));
    });

    test('isAdUri 关键字表', () {
      expect(HlsAdFilter.isAdUri('http://x/ads/1.ts'), isTrue);
      expect(HlsAdFilter.isAdUri('http://x/ADVERTISE/1.ts'), isTrue);
      expect(HlsAdFilter.isAdUri('http://x/video/1.ts'), isFalse);
    });
  });

  group('MediaProxy 端到端（本地夹具）', () {
    late HttpServer upstream;
    late String upstreamBase;

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBase = 'http://127.0.0.1:${upstream.port}';
      upstream.listen((req) async {
        final path = req.uri.path;
        final range = req.headers.value('range');
        if (path == '/index.m3u8') {
          req.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          req.response.write('''
#EXTM3U
#EXTINF:6.0,
$upstreamBase/seg1.ts
#EXTINF:6.0,
$upstreamBase/ads/seg2.ts
#EXTINF:6.0,
$upstreamBase/seg3.ts
''');
        } else if (path == '/seg1.ts' || path == '/seg3.ts') {
          // 校验透传带上 Range 与源级头。
          if (range != null && range != 'bytes=0-1') {
            req.response.statusCode = 416;
          } else {
            req.response.headers.contentType =
                ContentType('video', 'mp2t');
            req.response.write('TS:$path');
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() => upstream.close(force: true));

    test('wrap → 拉清单（净化+重写）→ 分片透传带 Range/头', () async {
      await MediaProxy.instance.acquire();
      addTearDown(MediaProxy.instance.release);
      final url = MediaProxy.instance.wrap('$upstreamBase/index.m3u8',
          headers: {'Referer': 'http://ref.example'});
      final res = await directClient().get(Uri.parse(url));
      expect(res.statusCode, 200);
      final body = res.body;
      expect(body, isNot(contains('ads/seg2')));
      expect(body, contains('/mp/'));

      // 代理后的 seg3 URL 再拉一次：代理 URL 是 base64，解码 u 参数匹配。
      String segLine = '';
      for (final line in body.split('\n')) {
        if (!line.startsWith('http')) continue;
        final u = Uri.parse(line).queryParameters['u'] ?? '';
        final upstreamUrl =
            utf8.decode(base64Url.decode(base64Url.normalize(u)));
        if (upstreamUrl.endsWith('/seg3.ts')) {
          segLine = line;
          break;
        }
      }
      expect(segLine, isNotEmpty);
      final segRes = await directClient()
          .get(Uri.parse(segLine), headers: {'Range': 'bytes=0-1'});
      expect(segRes.statusCode, 200);
      expect(segRes.body, 'TS:/seg3.ts');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
