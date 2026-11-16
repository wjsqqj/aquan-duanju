import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/motion/daily_pick.dart';

const List<SeriesSummary> _items = [
  SeriesSummary(id: '1', title: '山花烂漫'),
  SeriesSummary(id: '2', title: '雾都夜行'),
  SeriesSummary(id: '3', title: '长风渡'),
  SeriesSummary(id: '4', title: '井下之城'),
];

dynamic _state(WidgetTester tester) => tester.state(find.byType(FxDailyPick));

/// 视口 300 高滚动宿主：卡在 500px 下方，需滚 ≥260px 才 ≥40% 可见。
/// controller 直跳定位（drag 会带惯性，断言不确定）。
Widget _scrollHost(Widget child, ScrollController controller) => MaterialApp(
  home: Scaffold(
    body: SizedBox.fromSize(
      size: const Size(400, 300),
      child: CustomScrollView(
        controller: controller,
        slivers: [
          const SliverToBoxAdapter(child: SizedBox.shrink()),
          SliverToBoxAdapter(
            child: SizedBox.fromSize(size: const Size(400, 500)),
          ),
          SliverToBoxAdapter(child: child),
          SliverToBoxAdapter(
            child: SizedBox.fromSize(size: const Size(400, 500)),
          ),
        ],
      ),
    ),
  ),
);

/// 直挂宿主：FxDailyPick 首建即在视口内（静态直出/内容行的用例）。
///
/// [width] 决定走窄版（<720，封面下方一行文案）还是宽版（爱奇艺式信息卡 +
/// 缩略图切换条）。
Widget _bodyHost(
  Widget child, {
  bool disableAnimations = false,
  double width = 400,
  double height = 700,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: SizedBox(width: width, height: height, child: child),
      ),
    ),
  ),
);

FxDailyPick _pick({bool revealed = false, VoidCallback? onRevealedOnce}) =>
    FxDailyPick(
      // coverUrl 留空走占位路径：widget 级测试不装配 AppScope 全家桶。
      items: _items,
      revealed: revealed,
      onRevealedOnce: onRevealedOnce,
      onOpen: (_) {},
    );

void main() {
  group('dailyPickOf 日期种子', () {
    test('空列表返回 null（section 不渲染）', () {
      expect(
        dailyPickOf<SeriesSummary>(
          _items.take(0).toList(),
          DateTime(2026, 1, 15),
        ),
        isNull,
      );
    });

    test('同一天必然同一部（确定性）', () {
      final DateTime now = DateTime(2026, 1, 15);
      final SeriesSummary a = dailyPickOf(_items, now)!;
      final SeriesSummary b = dailyPickOf(
        _items,
        DateTime(2026, 1, 15, 23, 59),
      )!;
      expect(a.id, b.id);
      expect(a.id, _items[14 % 4].id);
    });

    test('跨天轮换：不同日期取不同槽位', () {
      // 2026-01-15 是年内第 14 天（14%4=2），01-18 是第 17 天（17%4=1）。
      expect(dailyPickOf(_items, DateTime(2026, 1, 15))!.id, _items[2].id);
      expect(dailyPickOf(_items, DateTime(2026, 1, 18))!.id, _items[1].id);
    });

    test('超过 12 张只在头部 12 张里轮换', () {
      final List<SeriesSummary> many = List<SeriesSummary>.generate(
        30,
        (i) => SeriesSummary(id: '$i'),
      );
      for (var day = 0; day < 400; day += 11) {
        final DateTime now = DateTime(2026, 1, 1).add(Duration(days: day));
        final int dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
        final String picked = dailyPickOf(many, now)!.id;
        expect(picked, many[dayOfYear % 12].id);
        expect(int.parse(picked), inInclusiveRange(0, 11));
      }
    });
  });

  group('dailyPickItemsOf 轮播候选', () {
    test('首位 = 当日种子，其余顺延且循环', () {
      final DateTime now = DateTime(2026, 1, 15); // 年内第 14 天，14%4=2
      final List<SeriesSummary> picks = dailyPickItemsOf(_items, now);
      expect(picks.first.id, dailyPickOf(_items, now)!.id);
      expect(picks.map((e) => e.id).toList(), <String>['3', '4', '1', '2']);
    });

    test('空列表返回空（section 不渲染）', () {
      expect(
        dailyPickItemsOf<SeriesSummary>(const [], DateTime(2026, 1, 15)),
        isEmpty,
      );
    });

    test('最多 6 张、不重复取同一条', () {
      final List<SeriesSummary> many = List<SeriesSummary>.generate(
        12,
        (i) => SeriesSummary(id: '$i'),
      );
      final List<SeriesSummary> picks = dailyPickItemsOf(
        many,
        DateTime(2026, 3, 1),
      );
      expect(picks.length, kDailyPickMaxItems);
      expect(picks.map((e) => e.id).toSet().length, picks.length);
    });
  });

  group('FxDailyPick 揭幕', () {
    testWidgets('首滚入才起跑：视口外不构建 → 露头即揭 → 一次性', (tester) async {
      var once = 0;
      final controller = ScrollController();
      await tester.pumpWidget(
        _scrollHost(_pick(onRevealedOnce: () => once++), controller),
      );
      await tester.pump();
      expect(
        find.byType(FxDailyPick),
        findsNothing,
        reason: 'sliver 懒构建：视口外未挂载',
      );
      expect(once, 0);

      // 滚 230px：只露一条边（<15%）→ 先不起跑，等滚进来或兜底。
      controller.jumpTo(230);
      await tester.pump();
      expect(find.byType(FxDailyPick), findsOneWidget);
      expect(_state(tester).debugStarted, isFalse, reason: '<15% 可见不起跑');
      expect(once, 0);

      // 再滚进视口 → 立即起跑记账（post-frame 测量后 forward；Ticker 首拍
      // 只定基准不吃时长——两拍 pump 才看得到推进，fx-motion-contract 沉淀）。
      controller.jumpTo(620);
      await tester.pump();
      expect(_state(tester).debugStarted, isTrue);
      expect(once, 1, reason: '起跑即记账一次');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_state(tester).debugRevealT, greaterThan(0));

      await tester.pumpAndSettle();
      expect(_state(tester).debugRevealT, 1);

      // 滚走再滚回：不重播（一次性）。
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      controller.jumpTo(620);
      await tester.pumpAndSettle();
      expect(_state(tester).debugRevealT, 1, reason: '揭幕不重播');
      expect(once, 1);
    });

    testWidgets('兜底：可见性测量没赶上（只露一条边）也照样揭，不留空白卡片', (tester) async {
      // 用户实测：软件第一次打开时今日推荐整块空白（裁剪进度停在 0）。
      var once = 0;
      final controller = ScrollController();
      await tester.pumpWidget(
        _scrollHost(_pick(onRevealedOnce: () => once++), controller),
      );
      await tester.pump();
      controller.jumpTo(230);
      await tester.pump();
      expect(_state(tester).debugStarted, isFalse);

      await tester.pump(const Duration(milliseconds: 1600));
      expect(_state(tester).debugStarted, isTrue, reason: '兜底计时器到点即揭');
      expect(once, 1);
      await tester.pumpAndSettle();
      expect(_state(tester).debugRevealT, 1);
    });

    testWidgets('reduceMotion：静态直出（不装动画，内容直接可见）', (tester) async {
      await tester.pumpWidget(_bodyHost(_pick(), disableAnimations: true));
      await tester.pump();
      expect(_state(tester).debugStarted, isTrue);
      expect(_state(tester).debugRevealT, 1);
      expect(find.text('今日推荐'), findsNWidgets(2), reason: '分区标题 + 徽标');
      expect(find.text('山花烂漫'), findsOneWidget);
    });

    testWidgets('revealed=true（本会话已揭过）：静态直出不重播', (tester) async {
      await tester.pumpWidget(
        _bodyHost(
          _pick(
            revealed: true,
            onRevealedOnce: () {
              fail('已揭过不应再记账');
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_state(tester).debugRevealT, 1);
      expect(find.text('山花烂漫'), findsOneWidget);
    });

    testWidgets('窄版（<720）：徽标 + 剧名 + 去看入口，文案在封面下方', (tester) async {
      await tester.pumpWidget(_bodyHost(_pick(), disableAnimations: true));
      await tester.pump();
      expect(find.text('今日推荐'), findsNWidgets(2), reason: '分区标题 + 徽标');
      expect(find.text('去看'), findsOneWidget);
      expect(find.byType(CoverImage), findsOneWidget);
    });

    testWidgets('宽版：圆钮在两侧空白中左右对称，且直径 80dp', (tester) async {
      await tester.pumpWidget(
        _bodyHost(_pick(), disableAnimations: true, width: 900),
      );
      await tester.pump();

      final Rect section = tester.getRect(find.byType(FxDailyPick));
      final Rect left = tester.getRect(find.byIcon(Icons.chevron_left));
      final Rect iconRight = tester.getRect(find.byIcon(Icons.chevron_right));
      final Rect cover = tester.getRect(find.byType(CoverImage).first);
      // 卡片左边缘 = 封面左边缘 − 间距 12 − 卡宽（比例 0.42，上限 520）。
      final double cardWidth = math.min(520.0, section.width * 0.42);
      final double cardLeft = cover.left - 12 - cardWidth;

      // 圆钮必须落在「页边 → 卡片」这段空白的正中（不是贴卡片）。
      expect(
        left.center.dx - section.left,
        closeTo((cardLeft - section.left) / 2, 0.5),
      );
      // 右侧镜像：到右页边 = 到封面右边缘（列宽同为 92，各 46）。
      expect(
        section.right - iconRight.center.dx,
        closeTo((section.right - cover.right) / 2, 0.5),
      );
      // 圆钮直径 80：图标 40 居中其中。
      final Rect dot = tester.getRect(
        find.ancestor(
          of: find.byIcon(Icons.chevron_left),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(dot.width, 80);
      expect(dot.height, 80);
    });

    testWidgets('宽版：左右大圆钮可切页（80dp 触达）', (tester) async {
      await tester.pumpWidget(
        _bodyHost(_pick(), disableAnimations: true, width: 900),
      );
      await tester.pump();
      expect(_state(tester).debugIndex, 0);

      // 圆钮直径 48：从图标中心往左上偏 18px 仍落在按钮内（不是只有图标能点）。
      final Offset right = tester.getCenter(find.byIcon(Icons.chevron_right));
      await tester.tapAt(right - const Offset(18, 0));
      await tester.pumpAndSettle();
      expect(_state(tester).debugIndex, 1);

      final Offset left = tester.getCenter(find.byIcon(Icons.chevron_left));
      await tester.tapAt(left + const Offset(18, 0));
      await tester.pumpAndSettle();
      expect(_state(tester).debugIndex, 0);
    });

    testWidgets('宽版（≥720）：左侧信息卡 + 下方缩略图切换条，点缩略图切页', (tester) async {
      await tester.pumpWidget(
        _bodyHost(_pick(), disableAnimations: true, width: 900),
      );
      await tester.pump();

      // 信息卡：徽标 + 当前剧名 + 去看；封面下方还有一条缩略图。
      expect(find.text('今日推荐'), findsNWidgets(2), reason: '分区标题 + 徽标');
      expect(
        find.text('山花烂漫'),
        findsNWidgets(2),
        reason: '信息卡标题 + 缩略图条标题',
      );
      expect(find.text('去看'), findsOneWidget);
      expect(
        find.byType(CoverImage),
        findsNWidgets(_items.length + 1),
        reason: '大图 1 张 + 缩略图 ${_items.length} 张',
      );

      // 点第 3 张缩略图（标题只在条里出现一次）→ 切到第 3 页。
      await tester.tap(find.text('长风渡'));
      await tester.pumpAndSettle();
      expect(_state(tester).debugIndex, 2);
      expect(find.text('长风渡'), findsNWidgets(2), reason: '信息卡 + 缩略图');
    });
  });
}
