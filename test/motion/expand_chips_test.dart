import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/widgets/motion/expand_chips.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';

Widget _host(int groups, {bool disableAnimations = false, bool tv = false}) {
  final Widget panel = Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (int g = 0; g < groups; g++)
        Wrap(
          children: <Widget>[
            for (int c = 0; c < 2; c++)
              FxExpandChip(group: g, index: c, child: Text('g$g-c$c')),
          ],
        ),
    ],
  );
  return MaterialApp(
    home: TvScope(
      formFactor: tv ? AppFormFactor.tv : AppFormFactor.phone,
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Center(
            child: FxExpandChips(groupCount: groups, child: panel),
          ),
        ),
      ),
    ),
  );
}

/// chip 自己的位移包装（最近的 Transform 祖先）；null = 已卸壳。
Transform? _chipTransform(WidgetTester tester, String label) {
  final Finder matches = find.ancestor(
    of: find.text(label),
    matching: find.byType(Transform),
  );
  if (matches.evaluate().isEmpty) return null;
  return tester.widget<Transform>(matches.first);
}

/// chip 的位移 y（Transform.translate → Matrix4 平移分量）。
double _chipDy(WidgetTester tester, String label) {
  final Transform? transform = _chipTransform(tester, label);
  if (transform == null) return 0;
  return transform.transform.getTranslation().y;
}

/// chip 自己的 opacity 包装（最近的 Opacity 祖先）；null = 已卸壳。
Opacity? _chipOpacity(WidgetTester tester, String label) {
  final Finder matches = find.ancestor(
    of: find.text(label),
    matching: find.byType(Opacity),
  );
  if (matches.evaluate().isEmpty) return null;
  return tester.widget<Opacity>(matches.first);
}

void main() {
  test('fxExpandTotalFor：150ms·组数，cap 1200ms', () {
    expect(fxExpandTotalFor(1), const Duration(milliseconds: 150));
    expect(fxExpandTotalFor(2), const Duration(milliseconds: 300));
    expect(fxExpandTotalFor(6), const Duration(milliseconds: 900));
    expect(fxExpandTotalFor(8), const Duration(milliseconds: 1200));
    expect(fxExpandTotalFor(99), const Duration(milliseconds: 1200)); // cap
    expect(fxExpandTotalFor(0), const Duration(milliseconds: 150)); // 下限兜底
  });

  test('中段先行分段：前 1/3 组先起、外圈滞后 15% 总长、组内 30ms 递进、共享时钟同时落定', () {
    // groups=6 → total=900ms、middleCount=2、middleLead=135ms。
    const double totalUs = 900000;
    final Interval g0c0 = fxExpandChipWindow(0, 0, 6);
    final Interval g1c0 = fxExpandChipWindow(1, 0, 6);
    final Interval g2c0 = fxExpandChipWindow(2, 0, 6);
    final Interval g5c0 = fxExpandChipWindow(5, 0, 6);
    expect(g0c0.begin, 0); // 首组立刻起跑
    expect(g1c0.begin, closeTo(30000 / totalUs, 1e-9)); // 中段组间 30ms 错拍
    // 外圈起点 = middleLead + 组序×stagger（组 2 → 135+60=195ms）。
    expect(g2c0.begin, closeTo(195000 / totalUs, 1e-9));
    expect(g5c0.begin, closeTo(285000 / totalUs, 1e-9));
    // 中段 → 外圈的「先行跳变」（组 1→2 相邻差 = lead 105ms + stagger 30ms）。
    expect(g2c0.begin - g1c0.begin, closeTo(165000 / totalUs, 1e-9));
    // 组内递进：+30ms。
    final Interval g2c1 = fxExpandChipWindow(2, 1, 6);
    expect(g2c1.begin - g2c0.begin, closeTo(30000 / totalUs, 1e-9));
    // 共享时钟：全部同时落定。
    expect(g0c0.end, 1.0);
    expect(g5c0.end, 1.0);
  });

  test('opacity 窗口：位移窗口的前 50% 完成', () {
    final Interval fade = fxExpandChipOpacityWindow(0, 0, 6);
    expect(fade.begin, 0);
    expect(fade.end, closeTo(0.5, 1e-9));
    final Interval fade2 = fxExpandChipOpacityWindow(2, 0, 6);
    expect(fade2.begin, closeTo(13 / 60, 1e-9));
    expect(fade2.end, closeTo(13 / 60 + (1 - 13 / 60) / 2, 1e-9));
  });

  testWidgets('弹入编排：起点 12px、opacity 前 50% 完成、easeOutBack 过冲、落定卸壳', (
    tester,
  ) async {
    await tester.pumpWidget(_host(6)); // total = 900ms
    // 首帧（t=0）：组 0 chip 0 停在起点（下方 12px、全透明）。
    expect(_chipDy(tester, 'g0-c0'), 12.0);
    expect(_chipOpacity(tester, 'g0-c0')!.opacity, 0.0);
    // 布局零变化：动效只做 Transform/opacity，chip 布局尺寸与落定后一致。
    final Size layoutAtStart = tester.getSize(find.text('g0-c0'));

    // t=0.25：opacity 恰好半程（窗口前 50% 线性），位移仍在下方。
    await tester.pump(const Duration(milliseconds: 225));
    expect(
      _chipOpacity(tester, 'g0-c0')!.opacity,
      moreOrLessEquals(0.5, epsilon: 1e-6),
    );
    final double dy25 = _chipDy(tester, 'g0-c0');
    expect(dy25, greaterThan(0));
    expect(dy25, lessThan(12));

    // t=0.5：easeOutBack 过冲段（p≈1.087）→ 位移越过终点（dy < 0）。
    await tester.pump(const Duration(milliseconds: 225));
    expect(_chipDy(tester, 'g0-c0'), lessThan(0));

    // 落定（t≥900ms）：包装层消失，无动画残留，布局尺寸不变。
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      find.descendant(
        of: find.byType(FxExpandChips),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(FxExpandChips),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(tester.getSize(find.text('g0-c0')), layoutAtStart);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion：不装 controller，静态直出', (tester) async {
    await tester.pumpWidget(_host(6, disableAnimations: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      find.descendant(
        of: find.byType(FxExpandChips),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(FxExpandChips),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(find.text('g0-c0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV：静态直出（焦点导航优先，不抢入场拍）', (tester) async {
    await tester.pumpWidget(_host(6, tv: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      find.descendant(
        of: find.byType(FxExpandChips),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('原地换组数：重算总长并重播一次（面板复用语义）', (tester) async {
    await tester.pumpWidget(_host(6));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.binding.transientCallbackCount, 0);
    // groupCount 变化 → didUpdateWidget 重播。
    await tester.pumpWidget(_host(3));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 1);
    // total(3)=450ms：一拍跑完，回到静止。
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
