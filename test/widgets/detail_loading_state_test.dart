import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 详情页加载态已从 E12「封面即骨架」混合骨架改为整页加载动画。
/// 详情页依赖 AppScope 全家桶（20+ stores + api），widget 级装配过重，
/// 与 hero_tag_test 同口径用源码结构断言提供接线证据。
void main() {
  test('_loadingBody：只渲染返回按钮 + 页面级 AppLoading', () {
    final String source = File('lib/screens/detail_screen.dart')
        .readAsStringSync();
    final int start = source.indexOf('Widget _loadingBody(BuildContext context)');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    expect(body, contains('AppLoading()'), reason: '页面级规范加载件');
    expect(body, contains('Center('), reason: 'AppLoading 组件自身不居中');
    expect(body, contains('BackButton('), reason: '加载期仍可返回');

    // 混合骨架的全部构成都不应再出现。
    expect(body, isNot(contains('DetailLoadingHeader')));
    expect(body, isNot(contains('CoverImage')));
    expect(body, isNot(contains('SliverAppBar')));
    expect(body, isNot(contains('FxMastheadTitle')));
    expect(body, isNot(contains('surface2')));

    // NEVER DO #7：不新画第三种加载规格。
    expect(body, isNot(contains('CircularProgressIndicator')));
  });

  test('DetailLoadingHeader 已移除，入口不再渲染骨架', () {
    final String source = File('lib/screens/detail_screen.dart')
        .readAsStringSync();
    expect(source, isNot(contains('class DetailLoadingHeader')));
    expect(source, isNot(contains('DetailLoadingHeader(')));
  });

  test('_errorBody：错误态仍保留左上返回（桌面不能只剩关窗口）', () {
    final String source = File('lib/screens/detail_screen.dart')
        .readAsStringSync();
    final int start = source.indexOf('Widget _errorBody(BuildContext context)');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    expect(body, contains('ErrorRetryView('), reason: '保留重试/立即重置');
    expect(body, contains('BackButton('), reason: '错误态必须能退出');
    expect(body, contains('Navigator.pop(context)'));

    // 层序：返回按钮必须画在全屏错误层之后，否则会被面板盖住点不到。
    expect(body.indexOf('Positioned.fill('),
        lessThan(body.indexOf('BackButton(')));
  });

  test('_loadSameName：过滤无集数的合集/帖子行（101001）', () {
    final String source = File('lib/screens/detail_screen.dart')
        .readAsStringSync();
    final int start = source.indexOf('Future<void> _loadSameName(');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    // 过滤谓词必须同时排除自身、空标题与 0 集数行（0 集是合集/帖子卡片）。
    final int where = body.indexOf('.where((s) =>');
    final int filterEnd = body.indexOf('.toList()', where);
    expect(where, greaterThan(0));
    expect(filterEnd, greaterThan(where));
    final String predicate = body.substring(where, filterEnd);
    expect(predicate, contains('s.id != selfId'));
    expect(predicate, contains('s.title.trim().isNotEmpty'));
    expect(predicate, contains('s.episodeCount > 0'),
        reason: '无集数行不是可播单剧，点进去会命中下架码');
  });
}
