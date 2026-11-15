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
Widget _bodyHost(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: child),
  ),
);

FxDailyPick _pick({bool revealed = false, VoidCallback? onRevealedOnce}) =>
    FxDailyPick(
      // coverUrl 留空走占位路径：widget 级测试不装配 AppScope 全家桶。
      item: _items.first,
      revealed: revealed,
      onRevealedOnce: onRevealedOnce,
      onOpen: () {},
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

  group('FxDailyPick 揭幕', () {
    testWidgets('首滚入才起跑：sliver 懒构建 → <40% 不起跑 → ≥40% 起跑且一次性', (tester) async {
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

      // 滚 260px：卡上缘露头但 <40% 可见 → 不起跑。
      controller.jumpTo(260);
      await tester.pump();
      expect(find.byType(FxDailyPick), findsOneWidget);
      expect(_state(tester).debugStarted, isFalse, reason: '<40% 可见不起跑');
      expect(once, 0);

      // 再滚到 ≥40% → 起跑记账（post-frame 测量后 forward；Ticker 首拍
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

    testWidgets('内容行：徽标 + 剧名 + 去看入口（实色阶梯 scrim，无渐变）', (tester) async {
      await tester.pumpWidget(_bodyHost(_pick(), disableAnimations: true));
      await tester.pump();
      expect(find.text('今日推荐'), findsNWidgets(2), reason: '分区标题 + 徽标');
      expect(find.text('去看'), findsOneWidget);
      expect(find.byType(CoverImage), findsOneWidget);
    });
  });
}
