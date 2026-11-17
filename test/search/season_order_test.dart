import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/search/season_order.dart';

List<String> _order(List<String> titles) => orderSeasonResults<String>(
      titles,
      titleOf: (title) => title,
    );

void main() {
  group('parseSeasonKey', () {
    test('阿拉伯数字与中文数字', () {
      expect(parseSeasonKey('万妖图录传第2季'), (group: '万妖图录传', season: 2));
      expect(parseSeasonKey('万妖图录传 第三季'), (group: '万妖图录传', season: 3));
      expect(parseSeasonKey('万妖图录传第十二季'), (group: '万妖图录传', season: 12));
      expect(parseSeasonKey('万妖图录传第二部'), (group: '万妖图录传', season: 2));
    });

    test('括号与尾部装饰不影响组名', () {
      expect(parseSeasonKey('万妖图录传（第二季）'), (group: '万妖图录传', season: 2));
      expect(parseSeasonKey('万妖图录传 第 4 季 '), (group: '万妖图录传', season: 4));
      expect(parseSeasonKey('万妖图录传·第二季'), (group: '万妖图录传', season: 2));
    });

    test('没有季标记返回 null', () {
      expect(parseSeasonKey('万妖图录传'), isNull);
      expect(parseSeasonKey(''), isNull);
      expect(parseSeasonKey('  '), isNull);
    });

    test('标题本身就是「第二季」时不做归并', () {
      expect(parseSeasonKey('第二季'), isNull);
    });
  });

  group('orderSeasonResults', () {
    test('同剧各季聚到首季位置并升序', () {
      final ordered = _order([
        '甲剧',
        '乙剧第一季',
        '丙剧',
        '乙剧第三季',
        '乙剧第二季',
      ]);
      expect(ordered, [
        '甲剧',
        '乙剧第一季',
        '乙剧第二季',
        '乙剧第三季',
        '丙剧',
      ]);
    });

    test('非季条目保持原相对顺序', () {
      final ordered = _order(['A', 'B', 'C']);
      expect(ordered, ['A', 'B', 'C']);
    });

    test('无季标记时返回原列表实例（避免无意义 rebuild）', () {
      final input = ['A', 'B', 'C'];
      expect(identical(_order(input), input), isTrue);
    });

    test('中文季号排序', () {
      expect(
        _order(['某剧第三季', '某剧第一季', '某剧第二季']),
        ['某剧第一季', '某剧第二季', '某剧第三季'],
      );
    });

    test('同组同季号（重复条目）按原顺序稳定', () {
      expect(
        _order(['某剧第二季', '某剧第一季', '某剧第二季']),
        ['某剧第一季', '某剧第二季', '某剧第二季'],
      );
    });

    test('单元素 / 空列表原样返回', () {
      expect(_order(['某剧第二季']), ['某剧第二季']);
      expect(_order(const []), isEmpty);
    });

    test('没有组名的季卡不当成同组', () {
      final ordered = _order(['第二季', '第三季', '某剧第一季']);
      expect(ordered, ['第二季', '第三季', '某剧第一季']);
    });
  });
}
