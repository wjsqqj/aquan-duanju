import 'dart:ui';

import 'package:aquan_duanju/core/soft_body/soft_ring.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SoftRing 物理', () {
    test('胶囊静止形状不被撑变形（168×56）', () {
      const size = Size(168, 56);
      final ring = SoftRing(
        center: Offset(size.width / 2, size.height / 2),
        radius: size.shortestSide / 2,
        physics: JellyPhysics.snap,
      );
      ring.setPolygon(
        Offset(size.width / 2, size.height / 2),
        SoftRing.superellipse(size.width, size.height),
      );

      for (var i = 0; i < 240; i++) {
        ring.step(1 / 120);
      }

      final bounds = ring.buildPath().getBounds();
      // 用圆的解析式约束会把这里撑成 100+ 高（design.md §13.7）
      expect(bounds.width, closeTo(size.width, 2));
      expect(bounds.height, closeTo(size.height, 2));
    });

    test('冲击后能收敛回静止形状', () {
      const size = Size(120, 120);
      final center = Offset(size.width / 2, size.height / 2);
      final ring = SoftRing(
        center: center,
        radius: 60,
        physics: JellyPhysics.snap,
      )..setCircle(center, 60);

      // 挤压：宽变多、高变少
      ring.squash(0.16);
      final deformed = ring.buildPath().getBounds();
      expect(deformed.width, greaterThan(size.width));
      expect(deformed.height, lessThan(size.height));

      for (var i = 0; i < 360; i++) {
        ring.step(1 / 120);
      }

      final bounds = ring.buildPath().getBounds();
      expect(bounds.width, closeTo(size.width, 4));
      expect(bounds.height, closeTo(size.height, 4));
      expect(ring.isSettled, isTrue);
    });

    test('三档手感参数与 design.md §13.3 一致', () {
      const snap = JellyPhysics.snap;
      expect(snap.edge, .90);
      expect(snap.bend, .55);
      expect(snap.shape, .055);
      expect(snap.damping, .997);
      expect(snap.pressure, .85);
      expect(snap.tether, .10);

      const flow = JellyPhysics.flow;
      expect(flow.edge, .70);
      expect(flow.bend, .24);
      expect(flow.shape, .017);
      expect(flow.damping, .992);
      expect(flow.pressure, .80);
      expect(flow.tether, .06);

      const melt = JellyPhysics.melt;
      expect(melt.edge, .44);
      expect(melt.bend, .12);
      expect(melt.shape, .007);
      expect(melt.damping, .978);
      expect(melt.pressure, .72);
      expect(melt.tether, .03);
    });

    test('superellipse 采样出的是非圆形状', () {
      final offsets = SoftRing.superellipse(168, 56);
      expect(offsets, hasLength(SoftRing.pointCount));
      final maxX = offsets.map((o) => o.dx).reduce((a, b) => a > b ? a : b);
      final maxY = offsets.map((o) => o.dy).reduce((a, b) => a > b ? a : b);
      expect(maxX, closeTo(84, 1));
      expect(maxY, closeTo(28, 1));
    });
  });
}
