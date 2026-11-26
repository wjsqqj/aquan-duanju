import 'dart:math';
import 'dart:typed_data';

import 'package:aquan_duanju/widgets/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

Int32List _starts(List<int> values) => Int32List.fromList(values);

void main() {
  group('danmakuWindow（时间窗二分）', () {
    test('空表返回空区间', () {
      final w = danmakuWindow(Int32List(0), 5000, 8000);
      expect(w.start, 0);
      expect(w.end, 0);
    });

    test('全部条目都在未来：窗口为空', () {
      final w = danmakuWindow(_starts([10000, 12000]), 5000, 8000);
      expect(w.start, w.end);
    });

    test('窗口两端都是闭区间（左闭右开下标）', () {
      // pos = 10000, scroll = 5000 → 命中 [5000, 10000]
      final w = danmakuWindow(
        _starts([4999, 5000, 9999, 10000, 10001]),
        10000,
        5000,
      );
      expect(w.start, 1, reason: '4999 已过期，不应包含');
      expect(w.end, 4, reason: '10001 尚未出现，不应包含');
    });

    test('8000 条随机数据：二分结果与线性扫描完全一致', () {
      final random = Random(42);
      final values = <int>[
        for (var i = 0; i < 8000; i++) random.nextInt(600000),
      ]..sort();
      final starts = _starts(values);

      for (var probe = 0; probe < 200; probe++) {
        final pos = random.nextInt(600000);
        const scroll = 8000;
        final from = pos - scroll;

        var expectedStart = values.length;
        var expectedEnd = values.length;
        for (var i = 0; i < values.length; i++) {
          if (values[i] >= from) {
            expectedStart = i;
            break;
          }
        }
        for (var i = 0; i < values.length; i++) {
          if (values[i] > pos) {
            expectedEnd = i;
            break;
          }
        }

        final w = danmakuWindow(starts, pos, scroll);
        expect(w.start, expectedStart, reason: 'pos=$pos start');
        expect(w.end, expectedEnd, reason: 'pos=$pos end');
      }
    });

    test('窗口内条数与总条数解耦（8000 条只命中一小段）', () {
      final starts = _starts([
        for (var i = 0; i < 8000; i++) i * 100,
      ]);
      final w = danmakuWindow(starts, 400000, 8000);
      expect(w.end - w.start, lessThanOrEqualTo(81));
    });
  });
}
