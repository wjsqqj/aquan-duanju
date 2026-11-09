import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/sources/episode_locator.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

UnifiedEpisode _ep(String title, int index) =>
    UnifiedEpisode(title: title, url: 'u$index', index: index);

/// 换线路保留当前集：旧实现写死 `_index = 0`，用户看到「跳回第 1 集」。
void main() {
  group('matchEpisodeIndex', () {
    test('集名唯一命中：线路顺序不同也能定位同一集', () {
      final from = [_ep('第1集', 1), _ep('第2集', 2), _ep('第3集', 3)];
      final to = [_ep('第3集', 1), _ep('第1集', 2), _ep('第2集', 3)];
      expect(matchEpisodeIndex(from: from, fromIndex: 2, to: to), 0);
    });

    test('编号写法归一化后命中（第3集 / 03）', () {
      final from = [_ep('第3集', 3)];
      final to = [_ep('01', 1), _ep('02', 2), _ep('03', 3)];
      expect(matchEpisodeIndex(from: from, fromIndex: 0, to: to), 2);
    });

    test('同名多条时按分集序号唯一命中', () {
      final from = [_ep('第3集', 3)];
      final to = [_ep('第3集', 1), _ep('第3集', 3)];
      expect(matchEpisodeIndex(from: from, fromIndex: 0, to: to), 1);
    });

    test('同名且序号都命中不到时按原下标回退', () {
      final from = [_ep('第9集', 9)];
      final to = [_ep('第9集', 1), _ep('第9集', 2)];
      expect(matchEpisodeIndex(from: from, fromIndex: 0, to: to), 0);
    });

    test('线路集数更少时 clamp 到最后一集', () {
      final from = [for (var i = 1; i <= 10; i++) _ep('第$i集', i)];
      final to = [for (var i = 1; i <= 6; i++) _ep('第$i集', i)];
      expect(matchEpisodeIndex(from: from, fromIndex: 8, to: to), 5);
    });

    test('空线路 / 空来源安全回退', () {
      expect(
        matchEpisodeIndex(from: const [], fromIndex: 3, to: [_ep('第1集', 1)]),
        0,
      );
      expect(
        matchEpisodeIndex(from: [_ep('第1集', 1)], fromIndex: 0, to: const []),
        0,
      );
    });

    test('下标越界安全', () {
      final from = [_ep('第1集', 1)];
      final to = [_ep('第1集', 1)];
      expect(matchEpisodeIndex(from: from, fromIndex: 99, to: to), 0);
    });
  });
}
