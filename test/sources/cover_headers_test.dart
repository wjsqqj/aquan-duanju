// 封面请求头合并单测（PRD 11-12 R3）：大小写不敏感、Referer 优先级。
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/cover_url.dart';

void main() {
  const ua = 'default-ua';

  group('mergeCoverHeaders', () {
    test('小写 user-agent 归一成单键，不再叠加默认 UA', () {
      final merged = mergeCoverHeaders(
        {'user-agent': 'src-ua'},
        defaultUa: ua,
      );
      expect(merged['User-Agent'], 'src-ua');
      expect(merged.keys.where((k) => k.toLowerCase() == 'user-agent').length, 1);
    });

    test('大小写混用只保留一个 User-Agent（后写覆盖）', () {
      final merged = mergeCoverHeaders(
        {'user-agent': 'a', 'User-Agent': 'b'},
        defaultUa: ua,
      );
      expect(merged['User-Agent'], 'b');
    });

    test('没有 UA 时补默认值', () {
      expect(mergeCoverHeaders({}, defaultUa: ua)['User-Agent'], ua);
    });

    test('源配置自带 Referer 优先于入参', () {
      final merged = mergeCoverHeaders(
        {'REFERER': 'https://src.example.com/'},
        referer: 'https://api.example.com/',
        defaultUa: ua,
      );
      expect(merged['Referer'], 'https://src.example.com/');
    });

    test('源 Referer 为空时退回 referer 参数', () {
      final merged = mergeCoverHeaders(
        {'Referer': ''},
        referer: 'https://api.example.com/',
        defaultUa: ua,
      );
      expect(merged['Referer'], 'https://api.example.com/');
    });

    test('都没有时不产出 Referer 键', () {
      expect(mergeCoverHeaders({}, defaultUa: ua).containsKey('Referer'), isFalse);
    });

    test('其它 header 保留原大小写', () {
      final merged = mergeCoverHeaders(
        {'X-Custom': 'v'},
        defaultUa: ua,
      );
      expect(merged['X-Custom'], 'v');
    });
  });
}
