import 'dart:async';

import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/theme/app_tokens.dart';
import 'package:aquan_duanju/widgets/loading.dart';
import 'package:aquan_duanju/widgets/ui/app_pull_refresh.dart';
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

/// sliver 路线页面：AppPullRefresh 包 CustomScrollView（与 discover 同构）。
Widget _sliverPage(Future<void> Function() onRefresh) {
  return AppPullRefresh(
    onRefresh: onRefresh,
    child: CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        const SliverToBoxAdapter(
          child: SizedBox(height: 600, child: Center(child: Text('item'))),
        ),
      ],
    ),
  );
}

/// 分段下拽：拽住不放、逐段推进并在段间出帧，避开 tester.drag 一次成形的
/// fling 速度对 overscroll 读数的干扰。
Future<TestGesture> _holdAndPull(WidgetTester tester, double distance) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.text('item')),
  );
  double pulled = 0;
  while (pulled < distance) {
    final double step = (distance - pulled).clamp(0.0, 40.0).toDouble();
    await gesture.moveBy(Offset(0.0, step));
    pulled += step;
    await tester.pump();
  }
  return gesture;
}

/// 水滴 Transform 的纵向比例（Transform 在树上离水滴最近的那个）。
///
/// 不用 `getMaxScaleOnAxis`：它把 z 轴（恒 1）也算进去，读不出拉距变化。
double _dropletScale(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find
        .ancestor(
          of: find.byKey(AppPullRefresh.dropletKey),
          matching: find.byType(Transform),
        )
        .first,
  );
  return transform.transform.entry(1, 1);
}

void main() {
  testWidgets('drag：拉距驱动的水滴成形（未到触发线比例未满），不走 RefreshIndicator', (tester) async {
    await tester.pumpWidget(_host(_sliverPage(() => Completer<void>().future)));
    await tester.pump();

    // 拉距 40（未到 70 触发线）：水滴已出现，比例未满。
    final TestGesture gesture = await _holdAndPull(tester, 40.0);
    expect(find.byKey(AppPullRefresh.dropletKey), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
    final double partialScale = _dropletScale(tester);
    expect(partialScale, lessThan(0.95));

    // 回弹归位后重新深拉（单步 150，越过 70 触发线）：armed 满幅。
    // （不 pumpAndSettle：松手 fling 的弹道在测试时钟下用有限 pump 收尾。）
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final TestGesture deep = await tester.startGesture(
      tester.getCenter(find.text('item')),
    );
    await deep.moveBy(const Offset(0.0, 150.0));
    await tester.pump();
    expect(find.byKey(AppPullRefresh.dropletKey), findsOneWidget);
    expect(_dropletScale(tester), moreOrLessEquals(1.0));
    expect(find.byType(RefreshIndicator), findsNothing);

    await deep.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh：渲染 AppLoading.inline（NEVER DO #7，不新画加载规格）', (
    tester,
  ) async {
    final Completer<void> completer = Completer<void>();
    await tester.pumpWidget(_host(_sliverPage(() => completer.future)));
    await tester.pump();

    final TestGesture gesture = await _holdAndPull(tester, 150.0);
    await gesture.up();
    // 松手后回弹稳定在 60pt 保底位，进入 refresh 态。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(AppLoading), findsOneWidget);
    expect(find.byKey(AppPullRefresh.dropletKey), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('done：水滴 150ms 回吸淡出后归位', (tester) async {
    final Completer<void> completer = Completer<void>();
    await tester.pumpWidget(_host(_sliverPage(() => completer.future)));
    await tester.pump();

    final TestGesture gesture = await _holdAndPull(tester, 150.0);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AppLoading), findsOneWidget);

    completer.complete();
    await tester.pump();
    // done：水滴回吸（淡出目标 0，时长 150ms hover 档）。
    final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(fade.opacity, 0.0);
    expect(fade.duration, const Duration(milliseconds: 150));
    expect(find.byKey(AppPullRefresh.dropletKey), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(AppPullRefresh.dropletKey), findsNothing);
    expect(find.byType(AppLoading), findsNothing);
  });

  testWidgets('reduceMotion：done 淡出时长归零', (tester) async {
    final Completer<void> completer = Completer<void>();
    await tester.pumpWidget(
      _host(_sliverPage(() => completer.future), disableAnimations: true),
    );
    await tester.pump();

    final TestGesture gesture = await _holdAndPull(tester, 150.0);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AppLoading), findsOneWidget);

    completer.complete();
    await tester.pump();
    final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(fade.opacity, 0.0);
    expect(fade.duration, Duration.zero);
    // 时长为 0：下一帧透明度即归零（水滴元素要等回缩完才卸载）。
    // 注：MaterialApp 页面转场自带若干 FadeTransition，须限定在本组件
    // AnimatedOpacity 之内。
    await tester.pump(const Duration(milliseconds: 1));
    final FadeTransition fadeOut = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(AnimatedOpacity),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fadeOut.opacity.value, 0.0);
    await tester.pumpAndSettle();
    expect(find.byKey(AppPullRefresh.dropletKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('box 降级路线：品牌色 RefreshIndicator（brand/surface1 Token）', (
    tester,
  ) async {
    Color? brand;
    Color? surface1;
    Future<void> Function()? wired;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext context) {
            final AppTokens tokens = context.app;
            brand = tokens.colors.brand;
            surface1 = tokens.colors.surface1;
            Future<void> onRefresh() async {}
            wired = onRefresh;
            return AppPullRefresh(
              onRefresh: onRefresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  const SizedBox(
                    height: 600,
                    child: Center(child: Text('item')),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    final RefreshIndicator indicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    expect(indicator.color, brand);
    expect(indicator.backgroundColor, surface1);
    expect(indicator.onRefresh, same(wired));
    expect(find.byKey(AppPullRefresh.dropletKey), findsNothing);
  });

  testWidgets('box 降级路线：下拉触发 onRefresh', (tester) async {
    var refreshes = 0;
    await tester.pumpWidget(
      _host(
        AppPullRefresh(
          onRefresh: () async => refreshes++,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              const SizedBox(height: 600, child: Center(child: Text('item'))),
              Container(height: 600),
            ],
          ),
        ),
      ),
    );

    await tester.fling(find.text('item'), const Offset(0.0, 300.0), 1000.0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // 滚动动画收尾
    await tester.pump(const Duration(seconds: 1)); // 指示器落位动画
    await tester.pump(const Duration(seconds: 1)); // 指示器隐藏动画
    expect(refreshes, 1);
    expect(find.byKey(AppPullRefresh.dropletKey), findsNothing);
  });
}
