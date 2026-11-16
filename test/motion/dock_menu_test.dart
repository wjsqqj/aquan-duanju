import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/theme/app_metrics.dart';
import 'package:aquan_duanju/theme/app_tokens.dart';
import 'package:aquan_duanju/widgets/motion/dock_menu.dart';

const List<FxDockMenuItem<String>> _items = [
  FxDockMenuItem(value: '360P', label: '360P'),
  FxDockMenuItem(value: '720P', label: '720P'),
  FxDockMenuItem(value: '1080P', label: '1080P'),
  FxDockMenuItem(value: '4K', label: '4K'),
  FxDockMenuItem(value: '8K', label: '8K'),
  FxDockMenuItem(value: '原画', label: '原画'),
];

Widget _host({
  required ValueChanged<String> onSelected,
  ValueChanged<bool>? onOpenChanged,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: FxDockMenu<String>(
          value: '1080P',
          onSelected: onSelected,
          onOpenChanged: onOpenChanged,
          items: _items,
          child: const Padding(padding: EdgeInsets.all(12), child: Text('清晰度')),
        ),
      ),
    ),
  ),
);

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxDockMenu<String>));

/// 面板里某行外层 Opacity 的值（行交错进度的观察口）。
double _rowOpacity(WidgetTester tester, String label) {
  final Opacity opacity = tester.widget<Opacity>(
    find.ancestor(of: find.text(label), matching: find.byType(Opacity)).first,
  );
  return opacity.opacity;
}

void main() {
  testWidgets('开慢（540ms）：点开 120ms 时面板仍在伸展、行在交错', (tester) async {
    await tester.pumpWidget(_host(onSelected: (_) {}));
    await tester.tap(find.text('清晰度'));
    await tester.pump();
    expect(_state(tester).debugShown, isTrue);

    // 开拍未落定：openT < 1（540ms 开慢）；首行已浮现、末行未起跑。
    await tester.pump(const Duration(milliseconds: 120));
    expect(_state(tester).debugOpenT, lessThan(1));
    expect(_rowOpacity(tester, '360P'), greaterThan(0));
    expect(_rowOpacity(tester, '原画'), 0, reason: '末行交错尚未起跑');

    await tester.pumpAndSettle();
    expect(_state(tester).debugOpenT, 1);
    expect(find.text('原画'), findsOneWidget);
  });

  testWidgets('关快（360ms）：开拍 >500ms 未落定 vs 关拍 400ms 内消失', (tester) async {
    await tester.pumpWidget(_host(onSelected: (_) {}));
    // 时长 token：open=fxDockOpen(540)、close=fxDockClose(360)。
    expect(_state(tester).debugOpenDuration, AppMetrics.standard.fxDockOpen);
    expect(_state(tester).debugCloseDuration, AppMetrics.standard.fxDockClose);

    await tester.tap(find.text('清晰度'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_state(tester).debugOpenT, lessThan(1), reason: '开慢：500ms 未落定');
    await tester.pumpAndSettle();

    // 点外（屏障）关闭：400ms > 360ms 已收完（tap 竞技场结算需一帧 flush）。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_state(tester).debugShown, isFalse, reason: '关快：360ms 收完');
    await tester.pumpAndSettle();
  });

  testWidgets('Esc 关闭：面板焦点内按 Esc 收起', (tester) async {
    await tester.pumpWidget(_host(onSelected: (_) {}));
    await tester.tap(find.text('清晰度'));
    await tester.pumpAndSettle();
    expect(_state(tester).debugShown, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_state(tester).debugShown, isFalse);
  });

  testWidgets('选中回显与回调：点行触发 onSelected 并收起；选中行 brand 色', (tester) async {
    final List<String> picked = <String>[];
    await tester.pumpWidget(_host(onSelected: picked.add));
    await tester.tap(find.text('清晰度'));
    await tester.pumpAndSettle();
    // 选中行（value=1080P）文字 = colors.brand。
    final AppTokens tokens = tester.element(find.text('1080P')).app;
    final Text row = tester.widget<Text>(find.text('1080P'));
    expect(row.style?.color, tokens.colors.brand);

    await tester.tap(find.text('720P'));
    await tester.pumpAndSettle();
    expect(picked, <String>['720P']);
    expect(_state(tester).debugShown, isFalse);
  });

  testWidgets('贴底触发钮：面板改为向上弹（否则整块落在窗口外）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 触发钮贴窗口底边（模拟播放器底栏）。
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FxDockMenu<String>(
              value: '1080P',
              onSelected: (_) {},
              items: _items,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('清晰度'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('清晰度'));
    await tester.pump();
    expect(_state(tester).debugOpensUp, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('原画'), findsOneWidget);
  });

  testWidgets('onOpenChanged：弹出/收起各回一次（播放器据此暂停自动隐藏）', (tester) async {
    final List<bool> states = <bool>[];
    await tester.pumpWidget(
      _host(onSelected: (_) {}, onOpenChanged: states.add),
    );
    await tester.tap(find.text('清晰度'));
    await tester.pumpAndSettle();
    expect(states, <bool>[true]);

    await tester.tap(find.text('720P'));
    await tester.pumpAndSettle();
    expect(states, <bool>[true, false]);
  });

  testWidgets('reduceMotion：直开直关（无交错、时长归零）', (tester) async {
    await tester.pumpWidget(_host(onSelected: (_) {}, disableAnimations: true));
    await tester.tap(find.text('清晰度'));
    await tester.pump();
    expect(_state(tester).debugShown, isTrue);
    await tester.pumpAndSettle();
    expect(_state(tester).debugOpenT, 1, reason: '时长归零直开');
    expect(_rowOpacity(tester, '原画'), 1, reason: '无交错');
    expect(_state(tester).debugOpenDuration, Duration.zero);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_state(tester).debugShown, isFalse);
  });
}
