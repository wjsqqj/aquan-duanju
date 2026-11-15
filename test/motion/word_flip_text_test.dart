import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/word_flip_text.dart';

const TextStyle _style = TextStyle(fontSize: 20);

// 测试字体（Ahem）每字符宽度 = fontSize：2 字词宽 40，3 字词宽 60。
const String _two = '短剧';
const String _three = '漫剧长';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('值驱动模式', () {
    testWidgets('value 变化时翻一次：翻动中新旧词同树，落定只剩新词', (tester) async {
      await tester.pumpWidget(_host(WordFlipText(value: _two, style: _style)));
      expect(find.text(_two), findsOneWidget);

      // 换词： flight 进行中两份副本都在树里（ClipRect 遮罩内）。
      await tester.pumpWidget(
        _host(WordFlipText(value: _three, style: _style)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(_two), findsOneWidget);
      expect(find.text(_three), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text(_three), findsOneWidget);
      expect(find.text(_two), findsNothing);
    });

    testWidgets('行宽取候选词最宽者：翻动中块不跳', (tester) async {
      await tester.pumpWidget(_host(WordFlipText(value: _two, style: _style)));
      expect(tester.getSize(find.byType(WordFlipText)).width, 40.0);

      await tester.pumpWidget(
        _host(WordFlipText(value: _three, style: _style)),
      );
      // 翻动中容器宽 = max(旧 40, 新 60) = 60。
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getSize(find.byType(WordFlipText)).width, 60.0);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(WordFlipText)).width,
        60.0,
        reason: '翻动全程行宽稳定（不跳）',
      );
    });

    testWidgets('翻动中重复触发排队至多 1 个：后来者顶掉排队者', (tester) async {
      await tester.pumpWidget(_host(WordFlipText(value: _two, style: _style)));
      // 翻动 1：短剧 → 乙词。
      await tester.pumpWidget(_host(WordFlipText(value: '乙词', style: _style)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('乙词'), findsOneWidget);

      // 翻动中连给两个新值：排队位只有最后一个（丙词被丁词顶掉）。
      await tester.pumpWidget(_host(WordFlipText(value: '丙词', style: _style)));
      await tester.pumpWidget(_host(WordFlipText(value: '丁词', style: _style)));
      await tester.pumpAndSettle();
      expect(find.text('丁词'), findsOneWidget);
      expect(find.text('丙词'), findsNothing, reason: '排队位至多 1 个，先到者被顶掉');
      expect(find.text('乙词'), findsNothing);
      expect(find.text(_two), findsNothing);
    });

    testWidgets('语义标签：读屏拿到当前词而非双层副本', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(WordFlipText(value: _three, style: _style)),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(_three), findsOneWidget);
      handle.dispose();
    });
  });

  group('循环模式', () {
    // 测试环境里 hold Timer 在 pump 的 elapse 中触发，而 Ticker 首帧只吃
    // 部分时长——一拍（hold 50 + 翻 400）需要两次 500ms pump 才稳落定。
    Future<void> pumpBeat(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('hold 后自动翻下一个，翻完回到首词', (tester) async {
      await tester.pumpWidget(
        _host(
          WordFlipText.cycle(
            phrases: const ['a', 'b', 'c'],
            holdDuration: const Duration(milliseconds: 50),
            style: _style,
          ),
        ),
      );
      expect(find.text('a'), findsOneWidget);

      await pumpBeat(tester);
      expect(find.text('b'), findsOneWidget);
      await pumpBeat(tester);
      expect(find.text('c'), findsOneWidget);
      await pumpBeat(tester);
      expect(find.text('a'), findsOneWidget, reason: '轮换回到首词');

      // 清场：卸载取消 Timer，测试不留挂起任务。
      await tester.pumpWidget(_host(const SizedBox.shrink()));
    });

    testWidgets('phrases 换列表：立即翻到新列表首词', (tester) async {
      WordFlipText widget = WordFlipText.cycle(
        phrases: const ['a', 'b', 'c'],
        holdDuration: const Duration(milliseconds: 50),
        style: _style,
      );
      await tester.pumpWidget(_host(widget));
      widget = WordFlipText.cycle(
        phrases: const ['x', 'y'],
        holdDuration: const Duration(milliseconds: 50),
        style: _style,
      );
      await tester.pumpWidget(_host(widget));
      await pumpBeat(tester);
      expect(find.text('x'), findsOneWidget, reason: '新列表首词');
      expect(find.text('a'), findsNothing);

      // 继续轮换到第二个词，然后回到 x。
      await pumpBeat(tester);
      expect(find.text('y'), findsOneWidget);
      await pumpBeat(tester);
      expect(find.text('x'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox.shrink()));
    });
  });

  group('reduceMotion（AC20）', () {
    testWidgets('值模式：不播翻词，直接切换文本', (tester) async {
      await tester.pumpWidget(
        _host(
          WordFlipText(value: _two, style: _style),
          disableAnimations: true,
        ),
      );
      expect(find.text(_two), findsOneWidget);

      await tester.pumpWidget(
        _host(
          WordFlipText(value: _three, style: _style),
          disableAnimations: true,
        ),
      );
      // duration 归零 → 翻词同步落定（AnimationController 零时长直接 complete）。
      expect(find.text(_three), findsOneWidget);
      expect(find.text(_two), findsNothing, reason: '没有旧词副本残留');
    });

    testWidgets('循环模式：禁用自动轮换，停在首词', (tester) async {
      await tester.pumpWidget(
        _host(
          WordFlipText.cycle(
            phrases: const ['a', 'b', 'c'],
            holdDuration: const Duration(milliseconds: 20),
            style: _style,
          ),
          disableAnimations: true,
        ),
      );
      expect(find.text('a'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('a'), findsOneWidget, reason: '不启动轮换 Timer');
      expect(find.text('b'), findsNothing);
      expect(find.text('c'), findsNothing);
    });
  });
}
