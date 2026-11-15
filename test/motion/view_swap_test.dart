import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/widgets/motion/view_swap.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';

Widget _host(
  ValueListenable<bool> mode, {
  bool disableAnimations = false,
  bool tv = false,
  int rows = kViewSwapMaxRows,
}) => MaterialApp(
  home: TvScope(
    formFactor: tv ? AppFormFactor.tv : AppFormFactor.phone,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: FxViewSwap(
          listenable: mode,
          rows: rows,
          first: const _Label('列表视图'),
          second: const _Label('立体书架'),
        ),
      ),
    ),
  ),
);

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      SizedBox.expand(child: Center(child: Text(text)));
}

dynamic _state(WidgetTester tester) => tester.state(find.byType(FxViewSwap));

void main() {
  testWidgets('切换时序：出快 488ms 清场 → hold 180ms 空窗 → 入慢 1075ms 落位', (
    tester,
  ) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode));
    expect(_state(tester).debugAnimated, isTrue);
    expect(find.text('列表视图'), findsOneWidget);
    expect(find.text('立体书架'), findsNothing);
    expect(FxViewSwap.swapInProgress, isFalse);

    mode.value = true;
    await tester.pump(); // 起表首拍
    expect(FxViewSwap.swapInProgress, isTrue);

    // 出拍中（rows=8：320ms + 24ms×7 = 488ms）：旧层还在滑出。
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('列表视图'), findsOneWidget);
    expect(find.text('立体书架'), findsNothing);

    // 500ms > 488ms：出拍结束，hold 拍只有底色。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('列表视图'), findsNothing);
    expect(find.text('立体书架'), findsNothing);

    // 700ms > 488+180：入拍开始，新层升起中。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('立体书架'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('立体书架'), findsOneWidget);
    expect(find.text('列表视图'), findsNothing);
    expect(FxViewSwap.swapInProgress, isFalse);
  });

  testWidgets('反向切换（reverse）：出/入语义对调——旧层慢出、新层快入', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode));
    mode.value = true;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('立体书架'), findsOneWidget);

    mode.value = false;
    await tester.pump();
    // 500ms：处于入拍倒放段（慢段 1075ms 墙钟）——second 还在滑出。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('立体书架'), findsOneWidget);
    expect(find.text('列表视图'), findsNothing);
    // 1300ms：越过 hold（倒放空窗）——first 已从上滑回（快段）。
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('列表视图'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('列表视图'), findsOneWidget);
    expect(_state(tester).debugShowSecond, isFalse);
    expect(FxViewSwap.swapInProgress, isFalse);
  });

  testWidgets('reduceMotion：直切（无包装层，AC20）', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode, disableAnimations: true));
    expect(_state(tester).debugAnimated, isFalse);

    mode.value = true;
    await tester.pump();
    expect(find.text('立体书架'), findsOneWidget);
    expect(find.text('列表视图'), findsNothing);
    expect(FxViewSwap.swapInProgress, isFalse);
  });

  testWidgets('TV：直切（焦点导航优先，不抢过渡拍）', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode, tv: true));
    expect(_state(tester).debugAnimated, isFalse);

    mode.value = true;
    await tester.pump();
    expect(find.text('立体书架'), findsOneWidget);
    expect(FxViewSwap.swapInProgress, isFalse);
  });

  testWidgets('rows 上限 8：入拍交错跨度按 cap 折算', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode, rows: 99));
    expect(_state(tester).debugRows, kViewSwapMaxRows);
  });

  testWidgets('行波段：末行留 1/rows 实窗（不整拍隐身、拍尾落定）', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode));
    final dynamic state = _state(tester);
    const int rows = 8;
    // 入场：首行全程 ramp，末行起跑点 = 7/8、拍尾落定（旧公式起跑点 = 1
    // 是零窗退化——入拍全程 alpha 0、收尾帧闪现）。
    expect(state.debugBandAlpha(0, rows, 0.0, true), 0.0);
    expect(state.debugBandAlpha(0, rows, 0.5, true), closeTo(0.5, 1e-9));
    expect(state.debugBandAlpha(0, rows, 1.0, true), 1.0);
    expect(state.debugBandAlpha(7, rows, 0.5, true), 0.0); // 未起跑
    expect(state.debugBandAlpha(7, rows, 0.95, true), greaterThan(0.0));
    expect(state.debugBandAlpha(7, rows, 1.0, true), 1.0);
    // 离场对称：末行保持可见到最后 1/8 段。
    expect(state.debugBandAlpha(7, rows, 0.5, false), 1.0);
    expect(state.debugBandAlpha(7, rows, 1.0, false), 0.0);
    // 全 alpha 段（progress=1、离场起点）：波段全 1，稳态等价无遮罩。
    for (int i = 0; i < rows; i++) {
      expect(state.debugBandAlpha(i, rows, 1.0, true), 1.0);
      expect(state.debugBandAlpha(i, rows, 0.0, false), 1.0);
    }
  });

  testWidgets('切换中途反向：不重复计数，收尾后归零', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(_host(mode));
    mode.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 仍在出拍中途
    expect(FxViewSwap.swapInProgress, isTrue);
    mode.value = false; // 中途反向（若在 t≈0 反向会瞬间 dismissed，此处真正中途）
    await tester.pump();
    expect(FxViewSwap.swapInProgress, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('列表视图'), findsOneWidget);
    expect(FxViewSwap.swapInProgress, isFalse);
  });
}
