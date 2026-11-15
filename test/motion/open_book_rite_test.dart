import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/open_book_rite.dart';

int _revealed = 0;

Widget _host({bool disableAnimations = false, int total = 12}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: FxOpenBookRite(
        // coverUrl 留空走占位路径：widget 级测试不装配 AppScope 全家桶。
        coverUrl: '',
        chapterNumber: 1,
        chapterTotal: total,
        onRevealed: () => _revealed++,
      ),
    ),
  ),
);

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxOpenBookRite));

void main() {
  setUp(() {
    _revealed = 0;
  });

  testWidgets('编排总长 ≤2.4s（豁免 cap）且 = 各段 kit 常量之和', (tester) async {
    await tester.pumpWidget(_host());
    final Duration? total = _state(tester)!.debugTotalDuration;
    expect(total, fxCutTotal);
    expect(total!, lessThanOrEqualTo(const Duration(milliseconds: 2400)));
    // 段和口径：1300 + 80 + 90 + 90 + 560 = 2120ms。
    expect(
      fxCutCountWindow +
          fxCutBladeOpen +
          fxCutBladeClose +
          fxCutRevealGap +
          fxCutRevealFold,
      const Duration(milliseconds: 2120),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('分段时序：计数/剪切同步推进 → 剪完才折叠 → 揭示回调', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 120));
    expect(_state(tester)!.debugT, greaterThan(0));
    // 计数/剪切窗进行中：剪切未到头、折叠未开始。
    expect(
      _state(tester)!.debugCutT(_state(tester)!.debugT),
      allOf(greaterThan(0), lessThan(1)),
    );
    expect(_state(tester)!.debugFoldT(_state(tester)!.debugT), 0);
    expect(_revealed, 0);

    // 计数窗（1300ms）走完：剪切到头，折叠仍未开始（刀片还有张开/合拢拍）。
    await tester.pump(const Duration(milliseconds: 1300));
    expect(_state(tester)!.debugCutT(_state(tester)!.debugT), 1);
    expect(_state(tester)!.debugFoldT(_state(tester)!.debugT), 0);

    // 揭示窗推进：折叠进行中。
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      _state(tester)!.debugFoldT(_state(tester)!.debugT),
      allOf(greaterThan(0), lessThan(1)),
    );

    await tester.pumpAndSettle();
    expect(_state(tester)!.debugFoldT(_state(tester)!.debugT), 1);
    expect(_revealed, 1, reason: '折叠完成才发揭示回调');
  });

  testWidgets('点按跳过：任意点按直接跳到揭示窗起点并照样发回调', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    final double revealStart = _state(tester)!.debugRevealStartT;

    await tester.tap(find.byType(FxOpenBookRite));
    await tester.pump();
    expect(_state(tester)!.debugT, revealStart, reason: '跳过 = 跳到揭示窗起点');
    expect(_revealed, 0);

    await tester.pumpAndSettle();
    expect(_revealed, 1, reason: '跳过后的揭示同样回调');
  });

  testWidgets('reduceMotion：完全不播，直发揭示回调（阅读器直进）', (tester) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(_state(tester)!.debugT, 1, reason: '直跳终态，无中间过程');
    expect(_revealed, 1);
  });

  testWidgets('计数语义：数字条旁落「第 1 章 / 共 N 章」（非 0→100 进度）', (tester) async {
    await tester.pumpWidget(_host(total: 36));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章 / 共 36 章'), findsOneWidget);
  });
}
