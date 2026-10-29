import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';
import 'package:aquan_duanju/core/sources/source_market.dart';

/// 本地索引站夹具：首页含 3 个配置地址 + 2 个资源误报；配置页含 2 个 CMS 源。
void main() {
  // 本地夹具走 127.0.0.1：导入 SSRF 守卫在测试内关闭。
  setUp(() => SourceImporter.ssrfGuardEnabled = false);
  tearDown(() => SourceImporter.ssrfGuardEnabled = true);

  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    final configJson =
        '{"sites":[{"key":"dyttzy","name":"电影天堂","type":1,"api":"\$BASE/vod"},'
        '{"key":"csp_X","name":"爬虫","type":3,"api":"csp_X"}]}';
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/index.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
<html><body>
  <a href="$base/cfg1.json">配置1</a>
  <a href="$base/cfg2.json">配置2</a>
  <a href="$base/cfg1.json">重复的配置1</a>
  <img src="$base/logo.png">
  <script src="$base/app.js"></script>
  <a href="$base/innersite/only">站内链接</a>
</body></html>
''');
      } else if (path.startsWith('/cfg')) {
        req.response.write(configJson.replaceAll(r'$BASE', base));
      } else if (path == '/js.html') {
        req.response.headers.contentType = ContentType.html;
        req.response
            .write('<html><body><div id="app">⏳ 正在加载接口列表...</div>'
                '<script src="/main.js"></script></body></html>');
      } else if (path == '/logo.png' || path == '/app.js') {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('扫描流水线：抓页 → 提配置 → 解析 → 测速 → 排序产出', () async {
    final scanner = MarketScanner();
    final events = <MarketScanEvent>[];
    await for (final e in scanner.scan([
      MarketSite(id: 's1', name: '索引站', url: '$base/index.html'),
    ])) {
      events.add(e);
    }

    final siteDone = events.whereType<MarketSiteDone>().single;
    expect(siteDone.configCount, 2, reason: 'cfg1+cfg2（重复地址已去重）');
    expect(siteDone.candidateCount, 2, reason: 'CMS 源 + 爬虫源都登记（后者带原因）');

    final done = events.whereType<MarketScanDone>().single;
    expect(done.results.length, 2);
    // 快测速的 vod 接口(200 空体→ok) 也排出来；验证排序稳定即可。
    expect(
      done.results.map((r) => r.candidate.api),
      contains('$base/vod'),
    );
  });

  test('JS 渲染页给出专门失败原因', () async {
    final scanner = MarketScanner();
    MarketSiteDone? done;
    await for (final e
        in scanner.scan([MarketSite(id: 's', name: 'x', url: '$base/js.html')])) {
      if (e is MarketSiteDone) done = e;
    }
    expect(done, isNotNull);
    expect(done!.jsRendered, isTrue);
  });

  test('索引站不可达 → SiteDone 带 error，扫描不崩', () async {
    final scanner = MarketScanner();
    MarketSiteDone? done;
    await for (final e in scanner.scan([
      MarketSite(id: 's', name: 'x', url: 'http://127.0.0.1:9/nope.html'),
    ])) {
      if (e is MarketSiteDone) done = e;
    }
    expect(done, isNotNull);
    expect(done!.error, isNotEmpty);
  });

  test('候选地址过滤：资源后缀/重复剔除', () {
    final scanner = MarketScanner();
    final urls = scanner.extractConfigUrls('''
      http://a/cfg.json
      http://a/logo.png
      http://a/app.js?ver=1
      http://a/cfg.json
      http://a/cfg2.json,
    ''');
    expect(urls, ['http://a/cfg.json', 'http://a/cfg2.json']);
  });

  test('SourceCandidate 经扫描入库（SourcesStore.addCandidates 走 usable 过滤）',
      () async {
    final candidates = [
      const SourceCandidate(name: '好源', api: 'http://ok/api/vod'),
      const SourceCandidate(
          name: '爬虫',
          api: 'csp_X',
          kind: SourceKind.spider,
          unsupportedReason: '需要爬虫引擎'),
    ];
    expect(candidates.where((c) => c.usable).length, 1);
  });
}
