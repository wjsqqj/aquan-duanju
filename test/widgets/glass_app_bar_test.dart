import 'package:aquan_duanju/widgets/glass/glass_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 玻璃顶栏的状态栏避让（安卓 edge-to-edge）。
///
/// 用户实测：安卓上「短剧 / 漫剧 / 电影 / 小说」那行标题与右侧图标被系统
/// 状态栏（电量栏）压住、点不到搜索。
void main() {
  Widget host({required EdgeInsets padding, required Widget body}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(padding: padding),
          child: Scaffold(
            extendBodyBehindAppBar: true,
            appBar: GlassAppBar(
              title: '发现',
              actions: <Widget>[
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {},
                ),
              ],
            ),
            body: body,
          ),
        ),
      );

  testWidgets('有状态栏（安卓）：标题下移让开，不被状态栏压住', (tester) async {
    await tester.pumpWidget(
      host(padding: const EdgeInsets.only(top: 44), body: const SizedBox()),
    );
    await tester.pump();

    final Rect title = tester.getRect(find.text('发现'));
    expect(title.top, greaterThanOrEqualTo(44),
        reason: '标题必须在状态栏之下');
    final Rect search = tester.getRect(find.byIcon(Icons.search));
    expect(search.top, greaterThanOrEqualTo(44),
        reason: '右侧按钮同样要让开状态栏');
  });

  testWidgets('无状态栏（Windows）：标题位置与改前一致（顶部 0 起）', (tester) async {
    await tester.pumpWidget(
      host(padding: EdgeInsets.zero, body: const SizedBox()),
    );
    await tester.pump();

    final Rect title = tester.getRect(find.text('发现'));
    expect(title.top, lessThan(24), reason: '桌面没有状态栏，不额外留空');
  });
}
