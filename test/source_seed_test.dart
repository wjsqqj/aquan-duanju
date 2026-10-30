import 'dart:io';

import 'package:aquan_duanju/core/sources/market_classify.dart';
import 'package:aquan_duanju/core/sources/source_export.dart';
import 'package:aquan_duanju/core/sources/source_fetch.dart';
import 'package:aquan_duanju/core/sources/source_market.dart';
import 'package:aquan_duanju/core/sources/source_seed.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置种子', () {
    test('数量与类型分布', () {
      expect(kBuiltinSeeds.length, 66);
      expect(kBuiltinSeeds.where((s) => s.kind == SeedKind.line).length, 47);
      expect(
          kBuiltinSeeds.where((s) => s.kind == SeedKind.aggregator).length, 15);
      expect(kBuiltinSeeds.where((s) => s.kind == SeedKind.list).length, 4);
    });

    test('id 唯一且都有 http(s) 地址', () {
      final ids = kBuiltinSeeds.map((s) => s.id).toSet();
      expect(ids.length, kBuiltinSeeds.length);
      for (final seed in kBuiltinSeeds) {
        expect(seed.url.startsWith('http'), isTrue, reason: seed.id);
        expect(seed.name.trim(), isNotEmpty, reason: seed.id);
      }
    });

    test('中文域名已转 punycode', () {
      for (final seed in kBuiltinSeeds) {
        final host = Uri.parse(seed.url).host;
        expect(
          RegExp(r'^[\x20-\x7E]*$').hasMatch(host),
          isTrue,
          reason: '${seed.id} 的 host 含非 ASCII：$host',
        );
      }
    });

    test('URL 归一化', () {
      expect(normalizeSeedUrl(' https://A.com/x/ '), 'https://a.com/x');
      expect(normalizeSeedUrl('http://a.com/#frag'), 'http://a.com');
      expect(normalizeSeedUrl(''), '');
    });
  });

  group('SeedStore', () {
    late Directory dir;
    late SeedStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('seed_store');
      store = SeedStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('首载就是内置全量', () {
      expect(store.seeds.length, 66);
      expect(store.enabled.length, 66);
      expect(store.isEnabled('line_01'), isTrue);
    });

    test('禁用可持久化', () async {
      await store.setEnabled('line_01', false);
      expect(store.isEnabled('line_01'), isFalse);
      final reloaded = SeedStore(testDirectory: dir);
      await reloaded.ensureLoaded();
      expect(reloaded.isEnabled('line_01'), isFalse);
    });

    test('删除内置项只是隐藏，恢复预置后回来', () async {
      await store.remove('line_02');
      expect(store.seeds.any((s) => s.id == 'line_02'), isFalse);
      expect(store.hiddenCount, 1);
      await store.restoreBuiltin();
      expect(store.seeds.any((s) => s.id == 'line_02'), isTrue);
      expect(store.hiddenCount, 0);
    });

    test('自定义种子可增删且持久化', () async {
      final seed = await store.add('我的线路', 'https://example.com/tv', SeedKind.line);
      expect(store.seeds.length, 67);
      expect(store.isEnabled(seed.id), isTrue);

      final reloaded = SeedStore(testDirectory: dir);
      await reloaded.ensureLoaded();
      expect(reloaded.seeds.any((s) => s.id == seed.id), isTrue);

      await reloaded.remove(seed.id);
      expect(reloaded.seeds.length, 66);
    });

    test('byKind 分组', () {
      expect(store.byKind(SeedKind.line).length, 47);
      expect(store.byKind(SeedKind.aggregator).length, 15);
      expect(store.byKind(SeedKind.list).length, 4);
    });
  });

  group('配置结构识别', () {
    test('单仓', () {
      final info = classifyConfig(<String, dynamic>{
        'name': '某仓',
        'sites': [
          {'key': 'a', 'api': 'http://a/api'},
        ],
        'spider': 'https://x/spider.jar',
      })!;
      expect(info.shape, RepoShape.single);
      expect(info.siteCount, 1);
      expect(info.cleartextSpiderJar, isFalse);
    });

    test('明文 spider jar 被标记', () {
      final info = classifyConfig(<String, dynamic>{
        'sites': [
          {'key': 'a'},
        ],
        'spider': 'http://x/spider.jar',
      })!;
      expect(info.cleartextSpiderJar, isTrue);
    });

    test('多仓 storeHouse 优先于 urls', () {
      final info = classifyConfig(<String, dynamic>{
        'storeHouse': [
          {'sourceName': '子1', 'sourceUrl': 'https://a'},
          {'sourceName': '空', 'sourceUrl': ''},
        ],
        'urls': [
          {'name': 'u', 'url': 'https://b'},
        ],
      })!;
      expect(info.shape, RepoShape.multiStoreHouse);
      expect(info.children.length, 1);
      expect(info.children.first.url, 'https://a');
    });

    test('多仓 urls', () {
      final info = classifyConfig(<String, dynamic>{
        'urls': [
          {'name': 'u1', 'url': 'https://a'},
          {'name': 'u2', 'url': 'https://b'},
        ],
      })!;
      expect(info.shape, RepoShape.multiUrls);
      expect(info.children.length, 2);
      expect(info.shape.isMulti, isTrue);
    });

    test('无法识别', () {
      final info = classifyConfig(<String, dynamic>{'foo': 'bar'})!;
      expect(info.shape, RepoShape.unknown);
      expect(info.known, isFalse);
    });
  });

  group('载荷格式识别', () {
    test('常见形态', () {
      expect(detectPayloadFormat('{"sites":[]}'), PayloadFormat.json);
      expect(detectPayloadFormat('2423abcdef'), PayloadFormat.catvodAes);
      expect(detectPayloadFormat('abcdefgh**eyJhIjoxfQ=='), PayloadFormat.stego);
      expect(detectPayloadFormat('plain text'), PayloadFormat.unknown);
      expect(
        detectPayloadFormat('<pre>{"sites":[]}</pre>'),
        PayloadFormat.json,
      );
    });
  });

  group('URL 提取', () {
    final scanner = MarketScanner();

    test('保留 json/txt 配置，过滤静态资源', () {
      final urls = scanner.extractConfigUrls('''
        <a href="https://a.com/cfg.json">1</a>
        <a href="https://a.com/cfg.txt">2</a>
        <a href="https://a.com/logo.png">3</a>
        <a href="https://a.com/app.js">4</a>
        <a href="https://a.com/cfg.json">5</a>
        <a href="https://b.com/tv">6</a>
        <a href="https://c.com/about">7</a>
      ''');
      expect(urls, contains('https://a.com/cfg.json'));
      expect(urls, contains('https://a.com/cfg.txt'));
      expect(urls, contains('https://b.com/tv'));
      expect(urls, isNot(contains('https://a.com/logo.png')));
      expect(urls, isNot(contains('https://a.com/app.js')));
      expect(urls.where((u) => u == 'https://a.com/cfg.json').length, 1);
      expect(urls, isNot(contains('https://c.com/about')));
    });

    test('最多 60 条', () {
      final page = List.generate(100, (i) => 'https://x.com/c$i.json').join(' ');
      expect(scanner.extractConfigUrls(page).length, 60);
    });
  });

  group('导出', () {
    MarketNode leaf({
      required String url,
      required int totalMs,
      bool available = true,
      String name = '',
    }) =>
        MarketNode(
          id: url,
          name: name,
          url: url,
          shape: RepoShape.single,
          available: available,
          totalMs: totalMs,
          ttfbMs: totalMs ~/ 2,
        );

    test('多仓导出只含可用单仓叶子且按延迟升序', () {
      final roots = <MarketNode>[
        MarketNode(
          id: 'multi',
          name: '多仓',
          url: 'https://m',
          shape: RepoShape.multiUrls,
          available: true,
          children: [
            leaf(url: 'https://slow/tv', totalMs: 900),
            leaf(url: 'https://fast/tv', totalMs: 100),
            leaf(url: 'https://dead/tv', totalMs: 50, available: false),
          ],
        ),
        leaf(url: 'https://mid/tv', totalMs: 400),
      ];
      final json = exportMultiRepoJson(roots);
      expect(json.indexOf('https://fast/tv'), greaterThan(0));
      expect(json.indexOf('https://fast/tv'),
          lessThan(json.indexOf('https://mid/tv')));
      expect(json.indexOf('https://mid/tv'),
          lessThan(json.indexOf('https://slow/tv')));
      expect(json.contains('https://dead/tv'), isFalse);
    });

    test('代理前缀被清洗并去重', () {
      final roots = <MarketNode>[
        leaf(url: 'https://gh-proxy.org/https://raw.githubusercontent.com/a/b/main/c.json', totalMs: 100),
        leaf(url: 'https://raw.githubusercontent.com/a/b/main/c.json', totalMs: 200),
      ];
      final urls = exportPlainUrls(roots);
      expect(urls.split('\n').length, 1);
      expect(urls.startsWith('https://raw.githubusercontent.com'), isTrue);
    });

    test('sites JSON 结构', () {
      final json = exportSitesJson([
        // 这里只验证字段形状，不依赖完整 SourceConfig。
      ]);
      expect(json.contains('"sites"'), isTrue);
    });
  });
}
