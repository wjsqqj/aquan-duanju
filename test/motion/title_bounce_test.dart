import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/title_bounce.dart';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

dynamic _state(WidgetTester tester) => tester.state(find.byType(FxTitleBounce));

void main() {
  const String title = '风起洛阳';

  testWidgets('reduceMotion：静态直出（不装 controller，AC20）', (tester) async {
    await tester.pumpWidget(
      _host(const FxTitleBounce(text: title), disableAnimations: true),
    );
    expect(_state(tester).debugAnimated, isFalse);
    expect(find.text(title), findsOneWidget);
    await tester.pumpAndSettle();
    // 静态路径没有逐字拆分：只有一个整句 Text。
    expect(find.text('风'), findsNothing);
  });

  testWidgets('入场编排：post-frame 启动、逐字 stagger、落定切回整句 Text', (tester) async {
    await tester.pumpWidget(_host(const FxTitleBounce(text: title)));
    expect(_state(tester).debugAnimated, isTrue);
    expect(_state(tester).debugCharCount, title.characters.length);

    // 首帧（post-frame 回调已注册但 ticker 未推进）：全部字符 t=0。
    await tester.pump();
    expect(_state(tester).debugCharProgress(0), 0);

    // 150ms：字符 0 已起跑，字符 3 还在 stagger 等待（先后差 = stagger）。
    await tester.pump(const Duration(milliseconds: 150));
    final double p0 = _state(tester).debugCharProgress(0) as double;
    final double p3 = _state(tester).debugCharProgress(3) as double;
    expect(p0, greaterThan(0));
    expect(p3, lessThan(p0));

    // 弹跳期间逐字渲染（每个字符一个 Text），整句 Text 尚不存在。
    expect(find.text('风'), findsOneWidget);
    expect(find.text(title), findsNothing);

    await tester.pumpAndSettle();
    // 落定：整句 Text（与无动效渲染一致），逐字副本撤除。
    expect(find.text(title), findsOneWidget);
    expect(find.text('风'), findsNothing);
  });

  testWidgets('文本变更重播（详情换剧复用组件树场景）', (tester) async {
    await tester.pumpWidget(_host(const FxTitleBounce(text: title)));
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);

    const String next = '长安十二时辰';
    await tester.pumpWidget(_host(const FxTitleBounce(text: next)));
    expect(_state(tester).debugCharCount, next.characters.length);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final double p = _state(tester).debugCharProgress(0) as double;
    expect(p, greaterThan(0));
    expect(p, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text(next), findsOneWidget);
  });

  testWidgets('n>16 字符：stagger 压缩，总时长仍锁 2.4s 内（900ms 内落定）', (tester) async {
    const String long = '非常非常长的剧名要超出十六个字符的压缩阈值才行';
    await tester.pumpWidget(_host(const FxTitleBounce(text: long)));
    expect(_state(tester).debugCharCount, greaterThan(16));
    // 首帧 kick（contract 沉淀：pumpWidget 后首拍只吃部分时长，需先 pump 一次）。
    await tester.pump();
    // 不压缩的话总时长 = 600 + 35·(n-1) > 900ms；压缩后 < 900ms。
    await tester.pump(const Duration(milliseconds: 900));
    expect(_state(tester).debugCharProgress(0), 1);
    expect(find.text(long), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('Semantics：读屏只读完整标题（逐字副本排除）', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const FxTitleBounce(text: title)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getSemantics(find.byType(FxTitleBounce)).label, title);
    handle.dispose();
  });
}
