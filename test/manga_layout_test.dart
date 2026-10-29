import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/manga_layout.dart';

void main() {
  group('useSpread', () {
    test('开关关闭时永远不拼版', () {
      expect(
        useSpread(width: 1200, height: 800, enabled: false),
        isFalse,
      );
      expect(useSpread(width: 800, height: 1200, enabled: false), isFalse);
    });

    test('开关打开时只在横屏拼版', () {
      expect(useSpread(width: 1200, height: 800, enabled: true), isTrue);
      expect(useSpread(width: 800, height: 1200, enabled: true), isFalse);
      // 正方形不算横屏。
      expect(useSpread(width: 1000, height: 1000, enabled: true), isFalse);
    });
  });

  group('spreadGroups', () {
    test('偶数页两两成屏', () {
      expect(spreadGroups(4), const [
        [0, 1],
        [2, 3],
      ]);
    });

    test('奇数页最后一页单独成屏', () {
      expect(spreadGroups(5), const [
        [0, 1],
        [2, 3],
        [4],
      ]);
    });

    test('单页与空输入', () {
      expect(spreadGroups(1), const [
        [0],
      ]);
      expect(spreadGroups(0), isEmpty);
      expect(spreadGroups(-1), isEmpty);
    });
  });
}
