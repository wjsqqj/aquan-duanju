import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/fx_curves.dart';

void main() {
  group('Fx 曲线族端点（Curve 契约：0→0、1→1）', () {
    test('五族 Cubic 曲线两端点', () {
      final curves = <Curve>[
        Fx.glide,
        Fx.spring,
        Fx.glideOut,
        Fx.inOut,
        Fx.dockIn,
      ];
      for (final curve in curves) {
        expect(curve.transform(0.0), 0.0, reason: '$curve 起点必须为 0');
        expect(curve.transform(1.0), 1.0, reason: '$curve 终点必须为 1');
      }
    });

    test('spring 有过冲（值越过 1 再回落）', () {
      var maxV = 0.0;
      for (var i = 1; i < 100; i++) {
        final v = Fx.spring.transform(i / 100);
        if (v > maxV) maxV = v;
      }
      expect(maxV, greaterThan(1.0));
      expect(Fx.spring.transform(1.0), 1.0, reason: '过冲后必须落回 1');
    });

    test('quartOut = 1-(1-t)^4：快出软落', () {
      expect(Fx.quartOut.transform(0.0), 0.0);
      expect(Fx.quartOut.transform(1.0), 1.0);
      expect(Fx.quartOut.transform(0.5), closeTo(0.9375, 1e-9));
      // 快出：前 1/4 时程已跑完大半路程。
      expect(Fx.quartOut.transform(0.25), greaterThan(0.5));
    });
  });

  group('Fx.stepped 阶梯曲线（floor(t·n)/n）', () {
    test('stepped(4)：落在最近的阶上', () {
      final curve = Fx.stepped(4);
      expect(curve.transform(0.0), 0.0);
      expect(curve.transform(0.25), closeTo(0.25, 1e-9));
      expect(curve.transform(0.26), closeTo(0.25, 1e-9), reason: '同阶内不推进');
      expect(curve.transform(0.5), closeTo(0.5, 1e-9));
      expect(curve.transform(0.99), closeTo(0.75, 1e-9), reason: '末阶只在 t=1 落定');
      expect(curve.transform(1.0), 1.0);
    });

    test('stepped(1)：整段停在起点、末帧落终值（floor(t·1)/1）', () {
      final curve = Fx.stepped(1);
      expect(curve.transform(0.0), 0.0);
      expect(curve.transform(0.5), 0.0);
      expect(curve.transform(0.999), 0.0);
      expect(curve.transform(1.0), 1.0);
    });

    test('steps<=0 按单阶处理，不抛异常', () {
      final curve = Fx.stepped(0);
      expect(curve.transform(0.5), 0.0);
      expect(curve.transform(1.0), 1.0);
    });

    test('阶梯单调不减且值域不超 [0,1]', () {
      final curve = Fx.stepped(7);
      var prev = 0.0;
      for (var i = 0; i <= 700; i++) {
        final v = curve.transform(i / 700);
        expect(v, inInclusiveRange(0.0, 1.0));
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
      expect(prev, 1.0);
    });
  });
}
