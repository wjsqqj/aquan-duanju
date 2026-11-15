import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/fx_damp.dart';

/// 挂一个真实 vsync 的宿主，把 FxDamper 交给测试体。
class _DamperHost extends StatefulWidget {
  const _DamperHost({required this.onReady});

  final void Function(FxDamper damper) onReady;

  @override
  State<_DamperHost> createState() => _DamperHostState();
}

class _DamperHostState extends State<_DamperHost>
    with SingleTickerProviderStateMixin {
  FxDamper? _damper;

  @override
  void initState() {
    super.initState();
    _damper = FxDamper(vsync: this, rate: 8, epsilon: 0.01);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_damper != null) widget.onReady(_damper!);
    });
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _damper?.dispose();
    _damper = null;
    super.dispose();
  }
}

void main() {
  testWidgets('指数阻尼：帧率无关收敛，settled 后自动停表', (tester) async {
    FxDamper? damper;
    await tester.pumpWidget(_DamperHost(onReady: (d) => damper = d));
    damper!.target = 100;
    expect(damper!.isTicking, isTrue, reason: '非零差值必须起表');

    var last = damper!.value;
    var settled = false;
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(damper!.value, greaterThanOrEqualTo(last), reason: '收敛必须单调');
      last = damper!.value;
      if (damper!.isSettled) {
        settled = true;
        break;
      }
    }
    expect(settled, isTrue, reason: 'rate=8 时 300 帧内必须收敛');
    expect(damper!.value, 100.0, reason: 'settled 时值钉在终值');
    expect(damper!.isTicking, isFalse, reason: '收敛后必须自动停表（静止零开销）');

    // 停表后额外帧不再推进。
    await tester.pump(const Duration(seconds: 1));
    expect(damper!.value, 100.0);
  });

  testWidgets('setTarget：settled 后改目标自动重启 Ticker 并收敛到新目标', (tester) async {
    FxDamper? damper;
    await tester.pumpWidget(_DamperHost(onReady: (d) => damper = d));
    damper!.target = 50;
    while (!damper!.isSettled) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(damper!.isTicking, isFalse);

    damper!.target = 0;
    expect(damper!.isTicking, isTrue, reason: '反向差值必须重启 Ticker');
    while (!damper!.isSettled) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(damper!.value, 0.0);
    expect(damper!.isTicking, isFalse);
  });

  testWidgets('jumpTo：直跳终态并停表（reduceMotion 出口）', (tester) async {
    FxDamper? damper;
    await tester.pumpWidget(_DamperHost(onReady: (d) => damper = d));
    damper!.target = 100;
    await tester.pump(const Duration(milliseconds: 16));
    expect(damper!.isTicking, isTrue);

    damper!.jumpTo(42);
    expect(damper!.value, 42.0);
    expect(damper!.target, 42.0);
    expect(damper!.velocity, 0.0);
    expect(damper!.isSettled, isTrue);
    expect(damper!.isTicking, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(damper!.value, 42.0, reason: '停表后不再推进');
  });

  testWidgets('卡顿跳帧防护：单帧最多补 4 步，多余时间丢弃', (tester) async {
    FxDamper? damper;
    await tester.pumpWidget(_DamperHost(onReady: (d) => damper = d));
    damper!.target = 100;

    // 首帧 dt 用固定单步（对齐 jelly_surface 惯例）：100ms 的卡顿帧只吃 1 步。
    await tester.pump(const Duration(milliseconds: 100));
    expect(damper!.value, lessThan(10.0), reason: '首帧不得吃掉整个卡顿 gap');

    // 第二帧 dt=100ms → 12 步需求被夹到 4 步（≈33ms）。
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      damper!.value,
      inInclusiveRange(10.0, 40.0),
      reason: '4 步上限 ≈ 28%；若不封顶（200ms 指数）会到 ≈80%',
    );
  });
}
