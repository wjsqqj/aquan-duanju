import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/screens/detail_screen.dart';
import 'package:aquan_duanju/widgets/common.dart';

Widget _wrap(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(child: SizedBox(width: 180, height: 300, child: child)),
    ),
  ),
);

void main() {
  test('tag 单一事实源：fxHeroSeriesCoverTag 生成「fx-hero-series-cover:<id>」', () {
    expect(fxHeroSeriesCoverTag('701'), 'fx-hero-series-cover:701');
    expect(fxHeroSeriesCoverTag('a-1'), 'fx-hero-series-cover:a-1');
  });

  testWidgets('SeriesCard 源端：封面层包 Hero，tag 由同一函数生成', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SeriesCard(
          item: const SeriesSummary(id: '701', title: '万妖图录'),
          onTap: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final heroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
    expect(heroes, hasLength(1), reason: '卡片上只有封面一个 Hero（徽标/角标不飞）');
    expect(heroes.single.tag, fxHeroSeriesCoverTag('701'));
    // Hero 包在 ClipRRect 内侧（飞行副本 = 封面本体）。
    expect(
      find.ancestor(of: find.byType(Hero), matching: find.byType(ClipRRect)),
      findsOneWidget,
    );
  });

  testWidgets('reduceMotion：源端不包 Hero（与详情端不配对即不飞）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SeriesCard(
          item: const SeriesSummary(id: '701', title: '万妖图录'),
          onTap: () {},
        ),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Hero), findsNothing);
    expect(find.byType(CoverImage), findsOneWidget, reason: '封面本体仍在');
  });

  test('详情端 _header：同 tag Hero 包住头图结构（源码结构断言）', () {
    // 详情页依赖 AppScope 全家桶（20+ stores + api），widget 级装配过重；
    // 按 implement.md 的降级口径，目的端以「结构断言」提供配对证据：
    // 1) 单一事实源函数在本文件导出；2) _header 用同一函数构造唯一 Hero；
    // 3) 定宽 SizedBox 留在 Hero 外侧（飞行副本不被 108 钉死）。
    final source = File('lib/screens/detail_screen.dart').readAsStringSync();

    expect(
      source,
      contains('fx-hero-series-cover:'),
      reason: 'tag 常量定义在 detail_screen.dart（单一事实源）',
    );

    final heroCalls = RegExp(
      r'Hero\(\s*tag:\s*fxHeroSeriesCoverTag\(series\.id\)',
    ).allMatches(source);
    expect(heroCalls, hasLength(1), reason: '目的端唯一一处 Hero 接线（_header）');

    // 无条件包裹：目的端没有任何 reduceMotion 条件分支挡在 Hero 前。
    expect(
      RegExp(r'reduceMotion[^;]{0,80}Hero\(').hasMatch(source),
      isFalse,
      reason: '目的端无条件包 Hero（reduceMotion 只由源端条件包裹）',
    );

    // 定宽 108 在 Hero 外侧。
    expect(
      RegExp(r'SizedBox\(\s*width: 108,\s*child:\s*Hero\(').hasMatch(source),
      isTrue,
      reason: 'SizedBox(width:108) 必须在 Hero 外，否则飞行宽度被钉死',
    );

    // 相关推荐 SeriesCard 关 Hero（防同路由同 tag 硬断言）。
    expect(
      RegExp(r'HeroMode\(\s*enabled:\s*false').hasMatch(source),
      isTrue,
      reason: '_recommendSection 的推荐卡不参与 Hero',
    );
  });
}
