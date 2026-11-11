import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _items = <SeriesSummary>[
  SeriesSummary(id: 'a', title: 'A'),
  SeriesSummary(id: 'b', title: 'B'),
];

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 卡片是 0.62 的高宽比，默认 800x600 视口里两列一行就占满一屏，
/// 触底占位格根本不会被构建。加高视口让第二行（占位格）进入可见区。
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('SeriesGrid 加载更多', () {
    testWidgets('失败态显示重试块，且不自动触发加载', (tester) async {
      _tallViewport(tester);
      var loads = 0;
      var retries = 0;
      await tester.pumpWidget(_wrap(SeriesGrid(
        items: _items,
        hasMore: true,
        loadMoreFailed: true,
        onLoadMore: () => loads++,
        onRetryLoadMore: () => retries++,
        onTap: (_) {},
      )));
      await tester.pump();

      // 占位格按列数铺满一行，宽度自适应下可能不止一个，取首个即可。
      expect(find.text('加载失败，点按重试'), findsWidgets);
      // 关键不变量：失败态绝不能自动重试（否则就是无限请求）。
      expect(loads, 0);
      expect(find.byType(AppLoading), findsNothing);

      await tester.tap(find.text('加载失败，点按重试').first);
      await tester.pump();
      expect(retries, 1);
      expect(loads, 0);
    });

    testWidgets('正常态显示转圈并触发加载', (tester) async {
      _tallViewport(tester);
      var loads = 0;
      await tester.pumpWidget(_wrap(SeriesGrid(
        items: _items,
        hasMore: true,
        onLoadMore: () => loads++,
        onTap: (_) {},
      )));
      await tester.pump();

      expect(find.byType(AppLoading), findsWidgets);
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(loads, greaterThanOrEqualTo(1));
    });

    testWidgets('没有更多时不显示占位', (tester) async {
      _tallViewport(tester);
      var loads = 0;
      await tester.pumpWidget(_wrap(SeriesGrid(
        items: _items,
        hasMore: false,
        onLoadMore: () => loads++,
        onTap: (_) {},
      )));
      await tester.pump();

      expect(find.byType(AppLoading), findsNothing);
      expect(loads, 0);
    });
  });
}
