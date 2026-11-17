import 'package:aquan_duanju/core/volume_gesture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('volumeFromDrag（右半屏纵向手势）', () {
    test('上滑增大、下滑减小', () {
      expect(volumeFromDrag(50, -20), 60);
      expect(volumeFromDrag(50, 20), 40);
    });

    test('从 100 起下滑能得到小于 100 的值（bug 回归）', () {
      // 旧实现跨手势缓存起点，导致下滑也 clamp 成 100。
      expect(volumeFromDrag(100, 40), lessThan(100));
      expect(volumeFromDrag(100, 40), 80);
    });

    test('连续两次手势都从各自起点算，不复用上一次', () {
      final first = volumeFromDrag(30, -40);
      expect(first, 50);
      final second = volumeFromDrag(first, -40);
      expect(second, 70);
      final third = volumeFromDrag(second, 40);
      expect(third, 50);
    });

    test('0–100 clamp', () {
      expect(volumeFromDrag(10, 100), 0);
      expect(volumeFromDrag(90, -100), 100);
    });

    test('非法灵敏度不产生 NaN', () {
      final v = volumeFromDrag(42, 10, sensitivity: 0);
      expect(v, 42);
    });
  });
}
