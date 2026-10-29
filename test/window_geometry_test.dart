import 'dart:ui';

import 'package:aquan_duanju/core/window_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WindowGeometryGuard.isPersistable', () {
    test('最小化一律不落盘', () {
      expect(
        WindowGeometryGuard.isPersistable(
            minimized: true, size: const Size(1180, 760)),
        isFalse,
      );
    });

    test('最小化占位尺寸不落盘', () {
      expect(
        WindowGeometryGuard.isPersistable(
            minimized: false, size: const Size(158, 26)),
        isFalse,
      );
    });

    test('正常尺寸可落盘', () {
      expect(
        WindowGeometryGuard.isPersistable(
            minimized: false, size: const Size(320, 180)),
        isTrue,
      );
    });

    test('NaN 尺寸不落盘', () {
      expect(
        WindowGeometryGuard.isPersistable(
            minimized: false, size: const Size(double.nan, 760)),
        isFalse,
      );
    });
  });

  group('WindowGeometryGuard.sanitize', () {
    test('没有存档时用默认尺寸并居中', () {
      final g = WindowGeometryGuard.sanitize(null);
      expect(g.size, WindowGeometryGuard.defaultSize);
      expect(g.position, isNull);
    });

    test('最小化占位坐标被放弃，尺寸回落默认', () {
      final g = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(-32000, -32000, 158, 26),
      );
      expect(g.size, WindowGeometryGuard.defaultSize);
      expect(g.position, isNull);
    });

    test('工作区内位置保留', () {
      final g = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(100, 80, 1180, 760),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      expect(g.size, const Size(1180, 760));
      expect(g.position, const Offset(100, 80));
    });

    test('副屏负坐标在对应显示器存在时保留', () {
      final g = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(-1800, 100, 1180, 760),
        workAreas: const [
          Rect.fromLTWH(0, 0, 1920, 1080),
          Rect.fromLTWH(-1920, 0, 1920, 1080),
        ],
      );
      expect(g.position, const Offset(-1800, 100));
    });

    test('屏幕外位置被放弃（改为居中）', () {
      final g = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(5000, 5000, 1180, 760),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      expect(g.size, const Size(1180, 760));
      expect(g.position, isNull);
    });

    test('取不到显示器信息时只剔除明显占位坐标', () {
      final kept = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(-1800, 100, 1180, 760),
      );
      expect(kept.position, const Offset(-1800, 100));

      final dropped = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(-32000, -32000, 1180, 760),
      );
      expect(dropped.position, isNull);
    });

    test('超小尺寸回落默认尺寸但位置仍可保留', () {
      final g = WindowGeometryGuard.sanitize(
        const Rect.fromLTWH(100, 100, 200, 120),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1080)],
      );
      expect(g.size, WindowGeometryGuard.defaultSize);
      expect(g.position, const Offset(100, 100));
    });
  });
}
