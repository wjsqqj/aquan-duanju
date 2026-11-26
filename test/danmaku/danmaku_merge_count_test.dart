import 'package:aquan_duanju/core/bili/api.dart';
import 'package:aquan_duanju/core/danmaku/danmaku_merge.dart';
import 'package:aquan_duanju/widgets/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

List<DanmakuItem> _items(List<(int, String)> raw) => [
      for (final (ms, text) in raw) DanmakuItem(progressMs: ms, text: text),
    ];

List<CountedDanmaku<DanmakuItem>> _counted(
  List<(int, String)> raw, {
  int windowMs = kDanmakuMergeWindowMs,
}) =>
    mergeSameDanmakuCounted<DanmakuItem>(
      _items(raw),
      offsetOf: (item) => item.progressMs,
      textOf: (item) => item.text,
      windowMs: windowMs,
    );

void main() {
  group('mergeSameDanmakuCounted（×N 计数合并）', () {
    test('窗口内 3 条同句 → 1 条 repeat=3', () {
      final out = _counted([(1000, '+1'), (4000, '+1'), (12000, '+1')]);
      expect(out.length, 1);
      expect(out.first.repeat, 3);
      expect(out.first.item.progressMs, 1000, reason: '归并到最早一条');
    });

    test('超过窗口的重复重新出现（各自计数）', () {
      final out = _counted([(0, '哈哈'), (25000, '哈哈')]);
      expect(out.length, 2);
      expect(out.map((e) => e.repeat), [1, 1]);
    });

    test('比较时归一化空白与大小写', () {
      final out = _counted([(0, '  HAHA '), (1000, 'haha')]);
      expect(out.length, 1);
      expect(out.first.repeat, 2);
      expect(out.first.item.text, '  HAHA ', reason: '展示仍是原文');
    });

    test('空白文本直接丢弃', () {
      final out = _counted([(0, '   '), (1000, '+1')]);
      expect(out.length, 1);
      expect(out.first.item.text, '+1');
    });

    test('windowMs <= 0 关闭合并（每条 repeat=1）', () {
      final out = _counted([(0, '+1'), (100, '+1')], windowMs: 0);
      expect(out.length, 2);
      expect(out.every((e) => e.repeat == 1), isTrue);
    });

    test('不同文本互不影响', () {
      final out = _counted([(0, '好看'), (1000, '好听'), (2000, '好看')]);
      expect(out.length, 2);
      expect(out.first.repeat, 2);
    });
  });

  group('filterDanmakuItems（渲染条目）', () {
    test('合并开启时展示文本带 ×N', () {
      final out = filterDanmakuItems(
        items: _items([(0, '前方高能'), (1000, '前方高能'), (2000, '前方高能')]),
        blockWords: const {},
        mergeSame: true,
      );
      expect(out.length, 1);
      expect(out.first.text, '前方高能 ×3');
      expect(out.first.repeat, 3);
    });

    test('重复句只出现一次时保持原文（无 ×1 噪音）', () {
      final out = filterDanmakuItems(
        items: _items([(0, '独一无二')]),
        blockWords: const {},
        mergeSame: true,
      );
      expect(out.first.text, '独一无二');
    });

    test('合并关闭时全量保留', () {
      final out = filterDanmakuItems(
        items: _items([(0, '+1'), (100, '+1')]),
        blockWords: const {},
        mergeSame: false,
      );
      expect(out.length, 2);
      expect(out.every((e) => e.repeat == 1), isTrue);
    });

    test('被屏蔽的句子不参与计数', () {
      final out = filterDanmakuItems(
        items: _items([
          (0, '广告私信'),
          (1000, '正常'),
          (2000, '广告私信'),
        ]),
        blockWords: const {'广告'},
        mergeSame: true,
      );
      expect(out.map((e) => e.text), ['正常']);
    });
  });
}
