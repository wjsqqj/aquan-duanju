import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_probe.dart';

SourceConfig _cfg(String id, String api) =>
    SourceConfig(id: id, name: id, apis: [api]);

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/fast') {
        req.response.write('{"list":[]}');
        await req.response.close();
      } else if (path == '/slow') {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        req.response.write('{"list":[]}');
        await req.response.close();
      } else if (path == '/broken') {
        req.response.statusCode = 500;
        await req.response.close();
      } else if (path == '/hang') {
        // 不响应也不关闭：客户端超时。
        await Future<void>.delayed(const Duration(seconds: 30));
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  });

  tearDown(() async => server.close(force: true));

  test('探测 URL 组装：JSON 源加 ac=videolist，XML 源原样', () {
    expect(
      probeUrlFor(_cfg('a', '$base/api.php/provide/vod')),
      '$base/api.php/provide/vod?ac=videolist&pg=1',
    );
    expect(
      probeUrlFor(_cfg('b', '$base/api?ac=list')),
      '$base/api?ac=list',
    );
    final xml = SourceConfig(
        id: 'c', name: 'c', apis: ['$base/c'], kind: SourceKind.cmsXml);
    expect(probeUrlFor(xml), '$base/c');
  });

  test('单源三态：快/失败/超时', () async {
    final ok = await probeSource(_cfg('ok', '$base/fast'),
        timeout: const Duration(seconds: 2));
    expect(ok.state, ProbeState.ok);
    expect(ok.latencyMs, lessThan(2000));

    final bad = await probeSource(_cfg('bad', '$base/broken'),
        timeout: const Duration(seconds: 2));
    expect(bad.state, ProbeState.failed);
    expect(bad.reason, contains('500'));

    final hang = await probeSource(_cfg('hang', '$base/hang'),
        timeout: const Duration(milliseconds: 300));
    expect(hang.state, ProbeState.timeout);
  });

  test('批量测速：并发、进度事件、排序（成功在前按延迟升序）', () async {
    final configs = [
      _cfg('fast', '$base/fast'),
      _cfg('slow', '$base/slow'),
      _cfg('broken', '$base/broken'),
    ];
    final events = <ProbeEvent>[];
    await for (final e in probeSources(configs,
        concurrency: 2, timeout: const Duration(seconds: 3))) {
      events.add(e);
    }
    final progress = events.whereType<ProbeProgress>().toList();
    final finished = events.whereType<ProbeFinished>().single;

    expect(progress.length, 3);
    expect(finished.outcomes.length, 3);
    expect(finished.outcomes[0].sourceId, 'fast');
    expect(finished.outcomes[1].sourceId, 'slow');
    expect(finished.outcomes[2].sourceId, 'broken');
  });

  test('spider 源直接失败并说明原因', () async {
    final spider = SourceConfig(
      id: 'sp',
      name: 'sp',
      apis: ['csp_XPath'],
      kind: SourceKind.spider,
    );
    final outcome = await probeSource(spider);
    expect(outcome.state, ProbeState.failed);
    expect(outcome.reason, contains('爬虫'));
  });

  test('展示分级阈值：<500 快 / <2000 正常 / 其余偏慢', () {
    expect(probeLevel(100), ProbeLevel.fast);
    expect(probeLevel(499), ProbeLevel.fast);
    expect(probeLevel(500), ProbeLevel.normal);
    expect(probeLevel(1999), ProbeLevel.normal);
    expect(probeLevel(2000), ProbeLevel.slow);
  });

  test('JSON 序列化往返（事件数据无持久化，但 outcome 结构稳定）', () {
    final ok = const ProbeOutcome(
        sourceId: 'a', state: ProbeState.ok, latencyMs: 840);
    expect(ok.isOk, isTrue);
    expect(ok.latencyMs, 840);
    final outcome = const ProbeOutcome(
        sourceId: 'b', state: ProbeState.failed, reason: 'x');
    expect(outcome.isOk, isFalse);
  });
}
