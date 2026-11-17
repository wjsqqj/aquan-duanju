import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player_gestures.dart';

void main() {
  group('longPressZoneAt（宽度 300 时 1/3 = 100，2/3 = 200）', () {
    test('左 1/3 快退', () {
      expect(longPressZoneAt(dx: 0, width: 300), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 50, width: 300), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 99.9, width: 300), LongPressZone.rewind);
    });

    test('中 1/3 不响应', () {
      expect(longPressZoneAt(dx: 100, width: 300), LongPressZone.none);
      expect(longPressZoneAt(dx: 150, width: 300), LongPressZone.none);
      expect(longPressZoneAt(dx: 200, width: 300), LongPressZone.none);
    });

    test('右 1/3 快进', () {
      expect(longPressZoneAt(dx: 200.1, width: 300), LongPressZone.forward);
      expect(longPressZoneAt(dx: 260, width: 300), LongPressZone.forward);
      expect(longPressZoneAt(dx: 300, width: 300), LongPressZone.forward);
    });

    test('越界坐标夹到边界内', () {
      expect(longPressZoneAt(dx: -50, width: 300), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 999, width: 300), LongPressZone.forward);
    });

    test('宽度不合法时不响应', () {
      expect(longPressZoneAt(dx: 10, width: 0), LongPressZone.none);
      expect(longPressZoneAt(dx: 10, width: -1), LongPressZone.none);
    });

    test('竖屏手机宽度（393）同样三分', () {
      expect(longPressZoneAt(dx: 60, width: 393), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 196, width: 393), LongPressZone.none);
      expect(longPressZoneAt(dx: 330, width: 393), LongPressZone.forward);
    });
  });

  // 11-17 回归：双击曾改在 onTap（抬手）里比时间戳，量的是 up→up，
  // 慢一点的连点（200ms 间隔 + 80ms 按压）越过 300ms 就不触发，
  // 表现为「PC 双击不能全屏」。现在改成 down→down 记时刻、抬手消费。
  group('SurfaceTapArbiter', () {
    final t0 = DateTime(2026, 11, 17, 20, 0, 0);

    test('单击：不判双击', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 60))),
          isFalse);
    });

    test('标准连点（down→down 200ms，第二次按了 80ms）判双击', () {
      // 旧实现按 up→up 算 = 200 + 80 = 280ms，刚好擦边；连点稍慢就失败。
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      a.onDown(t0.add(const Duration(milliseconds: 200)));
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 280))),
          isTrue);
    });

    test('慢一点的连点（down→down 300ms）仍判双击', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      a.onDown(t0.add(const Duration(milliseconds: 300)));
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 380))),
          isTrue);
    });

    test('间隔超过窗口的两下单击不算双击', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      a.onDown(t0.add(const Duration(milliseconds: 600)));
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 660))),
          isFalse);
    });

    test('三连击只认第二下，第三下当单击', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      a.onDown(t0.add(const Duration(milliseconds: 100)));
      expect(
          a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 150))), isTrue);
      a.onDown(t0.add(const Duration(milliseconds: 200)));
      expect(
          a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 240))), isFalse,
          reason: '第三下不能再次触发全屏/暂停');
    });

    test('双击候选被长按/拖动吃掉：抬手太晚不判双击，且不污染下一击', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      a.onDown(t0.add(const Duration(milliseconds: 120)));
      // 第二下按了 2 秒（变成拖动/长按），抬手才回到手势判定。
      expect(a.consumeIsDoubleTap(t0.add(const Duration(seconds: 2))), isFalse);
      // 下一击是正常单击。
      a.onDown(t0.add(const Duration(seconds: 5)));
      expect(a.consumeIsDoubleTap(t0.add(const Duration(seconds: 5, milliseconds: 60))),
          isFalse);
    });

    test('候选被拖动/长按赢走后，1 秒内的下一击不能误判成双击', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      // 第二下落在窗口内 → 挂起候选；但这次按压变成拖动快进/长按快退，
      // 手势被它们赢走，`onTap` 永远不会来，候选没人消费。
      a.onDown(t0.add(const Duration(milliseconds: 100)));
      // 松手后再点头：距候选 800ms，仍在 pressLimit 内。
      a.onDown(t0.add(const Duration(milliseconds: 900)));
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 960))),
          isFalse, reason: '拖动手势之后的第一下必须是单击，移动端不能突然暂停');
    });

    test('一次判定只消费一次', () {
      final a = SurfaceTapArbiter();
      a.onDown(t0);
      a.onDown(t0.add(const Duration(milliseconds: 100)));
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 150))), isTrue);
      expect(a.consumeIsDoubleTap(t0.add(const Duration(milliseconds: 160))), isFalse);
    });
  });
}
