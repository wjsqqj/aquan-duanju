import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_registry.dart';

SourceConfig _cfg(String id,
    {bool pinned = false,
    bool enabled = true,
    int score = 0,
    int latency = 0}) {
  final c = SourceConfig(id: id, name: id, apis: ['http://x/$id'])
    ..pinned = pinned
    ..enabled = enabled;
  return c;
}

void main() {
  group('sortSourcesForDisplay', () {
    test('钉选 > 启用 > 健康分 > 延迟', () {
      final a = _cfg('a', score: 500);
      final b = _cfg('b', pinned: true, score: -100);
      final c = _cfg('c', enabled: false, score: 9999);
      final d = _cfg('d', score: 500, latency: 50);
      final e = _cfg('e', score: 500, latency: 10);

      final sorted = sortSourcesForDisplay([a, b, c, d, e],
          scoreOf: (s) => s.id == 'a' || s.id == 'e'
              ? 500
              : s.id == 'd'
                  ? 500
                  : s.id == 'b'
                      ? -100
                      : 9999,
          latencyOf: (s) => s.id == 'd' ? 50 : s.id == 'e' ? 10 : 100);

      expect(sorted.map((s) => s.id).toList(), ['b', 'e', 'd', 'a', 'c']);
    });
  });

  group('dedupeCandidates', () {
    test('按 kind+api 归一化去重，不可用候选剔除', () {
      final out = dedupeCandidates([
        SourceCandidate(name: 'A', api: 'http://x/api/'),
        SourceCandidate(name: 'A2', api: 'http://x/api'),
        const SourceCandidate(
            name: 'S', api: 'csp_X', kind: SourceKind.spider, unsupportedReason: 'x'),
        SourceCandidate(name: 'B', api: 'http://y/api'),
      ]);
      expect(out.length, 2);
      expect(out[0].name, 'A');
      expect(out[1].name, 'B');
    });
  });

  test('dedupeKeyForSeries：标题+年份', () {
    expect(dedupeKeyForSeries('三体', '2024'), '三体@2024');
  });
}
