import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player_layout.dart';

void main() {
  group('底栏紧凑阈值', () {
    test('常见竖屏手机宽度使用紧凑底栏', () {
      for (final width in <double>[320, 360, 393, 412, 419]) {
        expect(
          useCompactPlayerBar(desktop: false, width: width),
          isTrue,
          reason: '$width 应使用紧凑底栏',
        );
      }
    });

    test('达到阈值后不再紧凑', () {
      expect(useCompactPlayerBar(desktop: false, width: 420), isFalse);
      expect(useCompactPlayerBar(desktop: false, width: 780), isFalse);
    });

    test('桌面窄窗同样紧凑（不再按 desktop 放行）', () {
      // 桌面窗口可以拉到 360dp：旧逻辑下倍速/睡眠按钮会被挤出窗口。
      expect(useCompactPlayerBar(desktop: true, width: 360), isTrue);
      expect(useCompactPlayerBar(desktop: true, width: 200), isTrue);
      expect(useCompactPlayerBar(desktop: true, width: 900), isFalse);
    });

    test('阈值覆盖完整底栏的固定宽度', () {
      // 5 个主按钮 48dp + 睡眠(40) + 倍速(50) + 横竖屏(48) + padding(16)。
      const fixedBarWidth = 5 * 48.0 + 40 + 50 + 48 + 16;
      expect(fixedBarWidth, lessThanOrEqualTo(kCompactPlayerBarWidth));
    });
  });

  group('底栏横向滚动阈值', () {
    test('窄窗（含桌面窄窗）需要横向滚动', () {
      for (final width in <double>[360, 420, 519, 719]) {
        expect(useScrollablePlayerBar(width), isTrue, reason: '$width');
      }
    });

    test('宽窗不需要横向滚动', () {
      expect(useScrollablePlayerBar(720), isFalse);
      expect(useScrollablePlayerBar(1280), isFalse);
    });

    test('滚动阈值不窄于紧凑阈值（紧凑模式下仍可能横向滚动）', () {
      expect(kPlayerBarFullWidth, greaterThan(kCompactPlayerBarWidth));
    });
  });
}
