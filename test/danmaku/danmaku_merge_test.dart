import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/bili/api.dart';
import 'package:aquan_duanju/core/danmaku/danmaku_merge.dart';

List<DanmakuItem> _items(List<(int, String)> raw) => [
      for (final (ms, text) in raw) DanmakuItem(progressMs: ms, text: text),
    ];

List<DanmakuItem> _merge(List<(int, String)> raw, {int windowMs = 20000}) =>
    mergeSameDanmaku<DanmakuItem>(
      _items(raw),
      offsetOf: (item) => item.progressMs,
      textOf: (item) => item.text,
      windowMs: windowMs,
    );

void main() {
  group('mergeSameDanmaku（20s 同句合并）', () {
    test('窗口内的重复同句只保留最早一条', () {
      final kept = _merge([
        (1000, '+1'),
        (4000, '+1'),
        (12000, '+1'),
        (21000, '+1'),
      ]);
      expect(kept.map((e) => e.progressMs), [1000, 21000]);
    });

    test('超过窗口的重复重新出现', () {
      final kept = _merge([
        (0, '哈哈'),
        (25000, '哈哈'),
      ]);
      expect(kept.length, 2);
    });

    test('不同文本互不影响', () {
      final kept = _merge([
        (0, '好看'),
        (1000, '好听'),
        (2000, '好看'),
      ]);
      expect(kept.map((e) => e.text), ['好看', '好听']);
    });

    test('比较时忽略空白与大小写', () {
      final kept = _merge([
        (0, '  HAHA '),
        (1000, 'haha'),
        (2000, '哈  哈'),
        (3000, ' 哈 哈 '),
      ]);
      expect(kept.length, 2, reason: 'haha 合并成 1 条，哈 哈 合并成 1 条');
      expect(kept.map((e) => e.progressMs), [0, 2000]);
    });

    test('空白文本直接丢弃', () {
      final kept = _merge([
        (0, '   '),
        (1000, '+1'),
      ]);
      expect(kept.map((e) => e.text), ['+1']);
    });

    test('windowMs <= 0 关闭合并', () {
      final raw = [(0, '+1'), (100, '+1')];
      expect(_merge(raw, windowMs: 0).length, 2);
    });

    test('少于两条时原样返回', () {
      final raw = [(0, '+1')];
      expect(_merge(raw).length, 1);
      expect(_merge(const []).length, 0);
    });

    test('窗口边界：正好 20s 视为不重复', () {
      final kept = _merge([
        (0, '+1'),
        (kDanmakuMergeWindowMs, '+1'),
      ]);
      expect(kept.length, 2);
    });
  });

  group('normalizeDanmakuText', () {
    test('压缩空白 / 去首尾 / 小写', () {
      expect(normalizeDanmakuText('  哈  哈 '), '哈 哈');
      expect(normalizeDanmakuText('HAHA'), 'haha');
      expect(normalizeDanmakuText('\n+1\t'), '+1');
    });
  });
}
