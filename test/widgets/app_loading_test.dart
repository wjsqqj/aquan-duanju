import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/widgets/loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: child),
    ),
  );
}

/// 离头像 [image] 最近的 Transform（= 落步压缩的 Transform.scale，
/// 套在 Transform.rotate 内层，见 design §1.1）。
Transform _squashOf(WidgetTester tester, Image image) {
  return tester.widget<Transform>(
    find
        .ancestor(
          of: find.byWidget(image),
          matching: find.byType(Transform),
        )
        .first,
  );
}

/// 两个规格里的头像 Image（树序：页面级在前、行内级在后）。
List<Image> _avatars(WidgetTester tester) =>
    tester.widgetList<Image>(find.byType(Image)).toList();

void main() {
  testWidgets('两规格渲染：落步压缩触地达峰（walk=π）、跳顶归位（walk=π/2），行内级系数减半',
      (tester) async {
    await tester.pumpWidget(_host(
      const Column(children: <Widget>[AppLoading(), AppLoading.inline()]),
    ));
    await tester.pump(); // Ticker 首帧（elapsed ≈ 0）
    // 步频 1.1Hz → walk = π/2（跳顶）在 t ≈ 0.227s：q = cos²(walk) = 0，
    // wobble = sin(2π)·0.018·0 = 0 → 压缩完全归位（跳顶不压扁）。
    await tester.pump(const Duration(milliseconds: 227));
    List<Image> avatars = _avatars(tester);
    expect(avatars.length, 2);
    expect(avatars[0].height, 40); // 页面级 size 32 → 头像高 40
    expect(avatars[1].height, 25); // 行内级 size 20 → 头像高 25
    for (final Image image in avatars) {
      final Transform t = _squashOf(tester, image);
      expect(t.transform.entry(0, 0), moreOrLessEquals(1.0, epsilon: 0.005));
      expect(t.transform.entry(1, 1), moreOrLessEquals(1.0, epsilon: 0.005));
    }

    // walk = π（t ≈ 0.455s，bob 触地）：q = cos²(walk) 达峰 1；
    // wobble = sin(3π + π/2)·0.018·1 = -0.018，计入后：
    // 页面级 squashX = 1 + 0.055 - 0.018 = 1.037，squashY = 1 - 0.070 + 0.018 = 0.948。
    await tester.pump(const Duration(milliseconds: 228));
    avatars = _avatars(tester);
    final Transform page = _squashOf(tester, avatars[0]);
    expect(page.transform.entry(0, 0), moreOrLessEquals(1.037, epsilon: 0.005));
    expect(page.transform.entry(1, 1), moreOrLessEquals(0.948, epsilon: 0.005));
    // 行内级系数减半（0.028/0.035 + 余摆 0.009）：
    // squashX = 1 + 0.0275 - 0.009 = 1.0185，squashY = 1 - 0.035 + 0.009 = 0.974。
    final Transform inline = _squashOf(tester, avatars[1]);
    expect(inline.transform.entry(0, 0), moreOrLessEquals(1.0185, epsilon: 0.005));
    expect(inline.transform.entry(1, 1), moreOrLessEquals(0.974, epsilon: 0.005));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion：全静止（Ticker 不启动、压缩归零、位置不随帧变）',
      (tester) async {
    await tester.pumpWidget(_host(
      const Column(children: <Widget>[AppLoading(), AppLoading.inline()]),
      disableAnimations: true,
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    List<double> squashDiagonals() => _avatars(tester)
        .expand((Image image) {
          final Matrix4 m = _squashOf(tester, image).transform;
          return <double>[m.entry(0, 0), m.entry(1, 1)];
        })
        .toList();

    // q 恒 0 → squash 恒 1（精确相等，不是近似）。
    expect(squashDiagonals(), <double>[1.0, 1.0, 1.0, 1.0]);
    final double pageBottom = tester.widget<Positioned>(
      find.ancestor(
        of: find.byWidget(_avatars(tester)[0]),
        matching: find.byType(Positioned),
      ).first,
    ).bottom as double;

    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(squashDiagonals(), <double>[1.0, 1.0, 1.0, 1.0]);
    // bob 恒 0：头像 Positioned.bottom 一帧后不变。
    expect(
      tester.widget<Positioned>(
        find.ancestor(
          of: find.byWidget(_avatars(tester)[0]),
          matching: find.byType(Positioned),
        ).first,
      ).bottom,
      pageBottom,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('单 Ticker：N 个实例恰 N 个 transient callback（无额外 BuildTicker）',
      (tester) async {
    await tester.pumpWidget(_host(
      const Column(children: <Widget>[
        AppLoading(),
        AppLoading.inline(),
        AppLoading.inline(),
      ]),
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 3);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 3);
  });

  testWidgets('reduceMotion 恢复：disableAnimations 关闭后 Ticker 重启', (tester) async {
    await tester.pumpWidget(_host(
      const Column(children: <Widget>[AppLoading.inline()]),
      disableAnimations: true,
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(_host(
      const Column(children: <Widget>[AppLoading.inline()]),
    ));
    // MaterialApp 的 AnimatedTheme 会因新 ThemeData 实例隐式重放 200ms，
    // 先让它收尾，再断言只剩 AppLoading 自己的 Ticker。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 1);
  });
}
