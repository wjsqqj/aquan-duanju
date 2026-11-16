import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/widgets/ui/avatar_walk_loading.dart';
import 'package:aquan_duanju/widgets/ui/stage_blobs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({bool dark = false, bool disableAnimations = false}) {
  return MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: AvatarWalkLoading(),
    ),
  );
}

/// StageBlobs 内的 4 团光斑（Align 定位，树序稳定）。
List<AlignmentGeometry> _blobAlignments(WidgetTester tester) {
  return tester
      .widgetList<Align>(
        find.descendant(
          of: find.byType(StageBlobs),
          matching: find.byType(Align),
        ),
      )
      .map((Align align) => align.alignment)
      .toList();
}

/// AvatarWalkLoading 的 body Stack（StageBlobs 的最近 Stack 祖先）：
/// 首 child = 光斑层，次 child = Center(内容)。
/// 注意不能 `find.byType(FadeTransition)`：MaterialApp 路由转场层也含
/// FadeTransition（页面级），必须沿 body Stack 结构化取树。
Stack _bodyStack(WidgetTester tester) => tester.widget<Stack>(
  find
      .ancestor(of: find.byType(StageBlobs), matching: find.byType(Stack))
      .first,
);

/// 内容渐入：body Stack 里 Center 直接包着的 FadeTransition（child 即 Column）。
FadeTransition _contentFade(WidgetTester tester) {
  final Center center = _bodyStack(tester).children[1] as Center;
  return center.child! as FadeTransition;
}

void main() {
  testWidgets(
    '氛围光斑层存在：IgnorePointer(StageBlobs) 在背景之上、内容之下；dark 与 ground 同一判定源',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump();
      // 浅色主题 → dark=false（与 ground 色 `Colors.black26` 同源判定）。
      expect(tester.widget<StageBlobs>(find.byType(StageBlobs)).dark, isFalse);
      // 层级：body Stack 首个 child = IgnorePointer(StageBlobs)，内容 Center 在其后。
      final Stack body = _bodyStack(tester);
      expect(body.children.first, isA<IgnorePointer>());
      final IgnorePointer layer = body.children.first as IgnorePointer;
      expect((layer.child as StageBlobs).dark, isFalse);
      expect(body.children[1], isA<Center>());
      // 内容 Column 被渐入 FadeTransition 直接包裹（Center → FadeTransition → Column）。
      final FadeTransition fade = _contentFade(tester);
      expect(fade.child, isA<Column>());

      // 深色主题 → 同一判定源翻转 dark=true（与 ground 色 `Colors.white24` 同源）。
      // 先跨过 MaterialApp 的 AnimatedTheme 200ms 插值（插值中 Theme.of 亮度仍是
      // light 端），否则本帧拿到的还是 light 判定。
      await tester.pumpWidget(_host(dark: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<StageBlobs>(find.byType(StageBlobs)).dark, isTrue);
      expect(
        (_bodyStack(tester).children.first as IgnorePointer).child,
        isA<StageBlobs>(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduceMotion：渐入时长归零 → 首帧即全量呈现（opacity=1，无 transient callback）', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    // didChangeDependencies 同步置满值：未经额外 pump 推进动画，首帧已全量。
    expect(_contentFade(tester).opacity.value, 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(_contentFade(tester).opacity.value, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion：光斑静止（26s controller 停帧不 repeat，blob 位移恒定）', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    await tester.pump();
    // 四光斑布局原样；reduceMotion 分支置 value=0.3 而非 repeat。
    expect(_blobAlignments(tester).length, 4);
    expect(tester.binding.transientCallbackCount, 0);
    final List<AlignmentGeometry> before = _blobAlignments(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(_blobAlignments(tester), before);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常模式：光斑随 26s controller 漂移、渐入 250ms 推进（对照 reduceMotion 静止断言）', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    // 走路 Ticker + 光斑 26s controller + 渐入 controller。
    // 标语拖影（FxSmearWordmark）已于 2026-11-16 撤掉（用户反馈「像被油墨
    // 涂黑」），引导页改成干净的普通文本 → 常驻动画少一路。
    expect(tester.binding.transientCallbackCount, 3);
    final List<AlignmentGeometry> before = _blobAlignments(tester);
    await tester.pump(const Duration(milliseconds: 100));
    // 渐入进行中（100/250ms，线性）。
    expect(
      _contentFade(tester).opacity.value,
      moreOrLessEquals(0.4, epsilon: 0.01),
    );
    // 光斑位移已随 t 变化（reduceMotion 下该断言恒 false，见上一用例）。
    expect(_blobAlignments(tester), isNot(before));
    await tester.pump(const Duration(milliseconds: 500));
    // 渐入完成（600ms > 250ms）→ 只剩 2 个常驻动画（走路 + 光斑）。
    expect(_contentFade(tester).opacity.value, 1);
    expect(tester.binding.transientCallbackCount, 2);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.binding.transientCallbackCount, 2);
    expect(tester.takeException(), isNull);
  });
}
