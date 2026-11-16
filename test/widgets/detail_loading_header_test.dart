import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/screens/detail_screen.dart';
import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/theme/app_tokens.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/loading.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('无 coverHint：surface2 空盒 + 真实标题 + 静态占位条 + AppLoading.inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const DetailLoadingHeader(seriesId: '701', title: '万妖图录传')),
    );
    await tester.pump();

    final tokens = tester.element(find.byType(DetailLoadingHeader)).app;

    // 封面位：无 hint → surface2 空盒（不构造 CoverImage，入口零 API 依赖），
    // 未传 hint 的调用点行为不回归（PRD AC）。
    expect(find.byType(CoverImage), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == tokens.colors.surface2,
      ),
      findsOneWidget,
      reason: '无 hint 时封面位渲染 surface2 空盒',
    );

    // 真实标题立即渲染（widget.title），Hero 目的端 tag 同出一源。
    expect(find.text('万妖图录传'), findsOneWidget);
    final hero = tester.widget<Hero>(find.byType(Hero));
    expect(hero.tag, fxHeroSeriesCoverTag('701'));

    // 局部指示走 AppLoading 家族行内级（NEVER DO #7：即时内容 + 局部指示，
    // 不是第三种加载规格）。
    final loading = tester.widget<AppLoading>(find.byType(AppLoading));
    expect(loading.size, 20, reason: 'AppLoading.inline 规格（行内级 size 20）');

    // 占位条静态即设计：全树只有 AppLoading 一个 Ticker（无 shimmer 控制器，
    // reduceMotion 友好），且帧间不变。
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.transientCallbackCount, 1);
    expect(tester.takeException(), isNull);
  });

  test('有 coverHint 与无新增色值：源码结构断言', () {
    // 非空 url 的 CoverImage 需要 AppScope（api 下发），widget 级装配过重——
    // 按 hero_tag_test 的降级口径，以源码结构断言提供接线证据。
    final source = File('lib/screens/detail_screen.dart').readAsStringSync();
    final start = source.indexOf('class DetailLoadingHeader');
    final end = source.indexOf('/// 详情页入口');
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final section = source.substring(start, end);

    // 有 hint → CoverImage(url: hint)（内存缓存命中秒显）；无 hint → surface2
    // 空盒；Hero 目的端用同一 tag 生成函数（单一事实源契约）。
    expect(section, contains('CoverImage(url: hint)'));
    expect(section, contains('ColoredBox(color: tokens.colors.surface2)'));
    expect(section, contains('fxHeroSeriesCoverTag(seriesId)'));

    // 无新增色值：骨架只走 token（审计口径子集——字面色/就地样式零出现）。
    expect(section, isNot(contains('Colors.')));
    expect(RegExp(r'Color\(0x').hasMatch(section), isFalse);
    expect(RegExp(r'TextStyle\(').hasMatch(section), isFalse);
    expect(RegExp(r'fontSize:').hasMatch(section), isFalse);

    // 入口接线：DetailScreen 收 coverHint，加载分支渲染就地骨架。
    expect(source, contains('coverHint: widget.coverHint'));
    expect(source, contains('DetailLoadingHeader('));
  });
}
