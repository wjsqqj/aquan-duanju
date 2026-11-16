import 'package:aquan_duanju/widgets/glass/glass_app_bar.dart';
import 'package:aquan_duanju/widgets/motion/word_flip_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 玻璃顶栏与它下面内容的关系（安卓 edge-to-edge）。
///
/// 用户实测（1.12.3）：安卓与 PC 上「短剧/漫剧/电影/小说」那一行被
/// 「上新 / 社区 / 搜索」那一栏盖住 —— 玻璃带加高（避让状态栏）后，
/// body 里手写的 `Padding(top: 56)` 补偿不够，内容被顶栏压住。
void main() {
  Widget host({
    required EdgeInsets padding,
    required Widget Function(BuildContext context) bodyBuilder,
  }) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(padding: padding),
          // Builder 在 Scaffold **之外**：页面 build 里就是这样取顶栏占位的
          // （Scaffold 会给 body 移除顶部 padding，在 body 内读不到状态栏）。
          child: Builder(
            builder: (context) => Scaffold(
              extendBodyBehindAppBar: true,
              appBar: GlassAppBar(
                title: '发现',
                actions: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.new_releases),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () {},
                  ),
                ],
              ),
              body: bodyBuilder(context),
            ),
          ),
        ),
      );

  testWidgets('翻词标题（WordFlipText）不被右侧按钮栏盖住', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassAppBar(
            title: '发现',
            titleWidget: WordFlipText(value: '短剧', style: const TextStyle(fontSize: 22)),
            actions: <Widget>[
              IconButton(icon: const Icon(Icons.new_releases), onPressed: () {}),
              IconButton(icon: const Icon(Icons.people), onPressed: () {}),
              IconButton(icon: const Icon(Icons.search), onPressed: () {}),
            ],
          ),
          body: const SizedBox(),
        ),
      ),
    );
    await tester.pump();

    final Rect word = tester.getRect(find.text('短剧'));
    final Rect search = tester.getRect(find.byIcon(Icons.search));
    expect(word.right, lessThanOrEqualTo(search.left),
        reason: '翻词标题不能被「上新/社区/搜索」那一栏盖住');
  });

  testWidgets('顶栏内容与右侧按钮不重叠', (tester) async {
    await tester.pumpWidget(
      host(
        padding: EdgeInsets.zero,
        bodyBuilder: (_) => const SizedBox(),
      ),
    );
    await tester.pump();

    final Rect title = tester.getRect(find.text('发现'));
    final Rect search = tester.getRect(find.byIcon(Icons.search));
    expect(title.right, lessThanOrEqualTo(search.left),
        reason: '标题不能被右侧按钮盖住');
  });

  testWidgets('有状态栏时：body 首行在玻璃带下沿之下（不被顶栏盖住）', (tester) async {
    await tester.pumpWidget(
      host(
        padding: const EdgeInsets.only(top: 44),
        bodyBuilder: (context) => Padding(
          padding: EdgeInsets.only(top: GlassAppBar.bodyTopInset(context)),
          child: const Text('类型条'),
        ),
      ),
    );
    await tester.pump();

    final Rect bar = tester.getRect(find.text('发现'));
    final Rect chip = tester.getRect(find.text('类型条'));
    expect(chip.top, greaterThanOrEqualTo(bar.bottom),
        reason: 'body 首行必须在玻璃带下沿之下');
  });

  testWidgets('无状态栏（桌面）：body 首行紧贴玻璃带下沿，不多留空白', (tester) async {
    await tester.pumpWidget(
      host(
        padding: EdgeInsets.zero,
        bodyBuilder: (context) => Padding(
          padding: EdgeInsets.only(top: GlassAppBar.bodyTopInset(context)),
          child: const Text('类型条'),
        ),
      ),
    );
    await tester.pump();

    final Rect bar = tester.getRect(find.text('发现'));
    final Rect chip = tester.getRect(find.text('类型条'));
    expect(chip.top, greaterThanOrEqualTo(bar.bottom));
    expect(chip.top - bar.bottom, lessThan(24), reason: '桌面不留多余空白');
  });
}
