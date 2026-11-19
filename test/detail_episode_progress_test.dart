import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 详情页选集网格「已播白底」的回归（11-19）。
///
/// 演进过程（保留是为了别把踩过的坑再踩回去）：
/// 1) 最初网格只监听 downloads，不监听 history → back 回来白底不刷新。
/// 2) 修好后发现网格是页面第二个滚动视口（GridView 嵌 SliverToBoxAdapter）
///    → 局部格子重影。
/// 3) 当时「已播」还同时切了**文字样式**（未播=橙字 15/w600，
///    已播=灰字 13/w500）：两种字体几何不同，切换后橙色大字的下缘从
///    灰色小字下面露出来 → 白底格子上出现橙色残影。
/// 4) 最终形态：**只让背景色随已播变，文字样式恒定不变**。
///    文字从未变过，就不存在「旧字叠新字」的残影。
void main() {
  final source =
      File('lib/screens/detail_screen.dart').readAsStringSync();

  test('选集网格用 SliverGrid 进外层 CustomScrollView（单滚动视口）', () {
    expect(source, isNot(contains('GridView.builder(')),
        reason: '选集网格不得用 GridView（第二个滚动视口会重影）');
    expect(source, contains('SliverChildBuilderDelegate('));
    expect(source, contains('_episodeSlivers(context)'));
  });

  test('网格监听 history，保证 back 回来已播白底即时刷新', () {
    final start = source.indexOf('listenable: AppScope.read(context).history');
    expect(start, greaterThan(0),
        reason: '必须监听 history，否则从播放页返回后白底停在旧快照');
    expect(start, lessThan(source.indexOf('childCount: _episodes.length')));
  });

  test('已播判定按进度位置（看到第 32 集 → 1..31 都算已播）', () {
    expect(source, contains('h.finished '), reason: '保留 finished 分支');
    expect(source, contains('h.episode > ep.number'),
        reason: '已播口径 = 进度指针之前的集数');
  });

  test('【关键】文字样式恒定，不随 watched 变化', () {
    final start = source.indexOf('ep.number.toString()');
    expect(start, greaterThan(0));
    final end = source.indexOf('childCount: _episodes.length', start);
    final textBlock = source.substring(start, end);
    expect(textBlock, isNot(contains('watched ?')),
        reason: '文字样式一旦随状态切换，就会留下橙色残影');
    expect(textBlock, isNot(contains('color: watched')));
    expect(textBlock, contains('color: theme.colorScheme.onPrimaryContainer'));
  });

  test('背景色随 watched 切换（这才是用户要的白底提示）', () {
    // 定位网格里的 Container decoration（用 color: watched 反查）。
    final mark = source.indexOf('color: watched');
    expect(mark, greaterThan(0), reason: '背景色必须随已播切换');
    final window = source.substring(
      mark,
      mark + 260,
    );
    expect(window, contains('surfaceContainerHigh'), reason: '已播 = 表层白底');
    expect(window, contains('primaryContainer'), reason: '未播 = 主题橙底');
  });

  test('cell 带 ValueKey + 透明 Material（复用与点击反馈）', () {
    expect(source, contains('key: ValueKey(ep.id)'));
    expect(source, contains('color: Colors.transparent'));
  });

  test('播放器选集仍保留已播打钩（另一种口径未受影响）', () {
    final grid = File('lib/widgets/episode_grid.dart').readAsStringSync();
    expect(grid, contains('watchedEpisodes'));
    expect(grid, contains('check_rounded'));
  });
}
