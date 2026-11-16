import 'package:aquan_duanju/widgets/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DanmakuLaneAllocator 稳定轨道', () {
    test('同一 key 恒定同轨（滚动窗口进出不会跳行）', () {
      final allocator = DanmakuLaneAllocator(rows: 4);
      final lane =
          allocator.laneFor('1000|前方高能', progressMs: 1000, gapMs: 900);
      for (var i = 0; i < 10; i++) {
        expect(
          allocator.laneFor('1000|前方高能', progressMs: 1000, gapMs: 900),
          lane,
          reason: '第 $i 次查询仍应落在同一轨道',
        );
      }
      expect(allocator.debugLaneOf['1000|前方高能'], lane);
    });

    test('同一时刻进入的多条弹幕分散到不同轨道', () {
      final allocator = DanmakuLaneAllocator(rows: 4);
      final lanes = <int>{};
      for (var i = 0; i < 4; i++) {
        lanes.add(allocator.laneFor('$i|同刻', progressMs: 2000, gapMs: 900));
      }
      expect(lanes.length, 4, reason: '4 行应当分到 4 条不同轨道');
    });

    test('轨道下标永远小于行数', () {
      final allocator = DanmakuLaneAllocator(rows: 2);
      for (var i = 0; i < 50; i++) {
        expect(
          allocator.laneFor('$i|x', progressMs: 1000 + i * 10, gapMs: 900),
          lessThan(2),
        );
      }
    });

    test('占用到期的轨道优先复用', () {
      final allocator = DanmakuLaneAllocator(rows: 3);
      expect(allocator.laneFor('a', progressMs: 0, gapMs: 900), 0);
      expect(allocator.laneFor('b', progressMs: 0, gapMs: 900), 1);
      // a 的占用（0 + 900ms）已过期 → 回到 0 轨。
      expect(allocator.laneFor('c', progressMs: 1000, gapMs: 900), 0);
    });

    test('条目表有上限（长视频不无限增长）', () {
      final allocator = DanmakuLaneAllocator(rows: 4);
      for (var i = 0; i < 900; i++) {
        allocator.laneFor('$i|刷屏', progressMs: i * 100, gapMs: 100);
      }
      expect(allocator.debugLaneOf.length, lessThanOrEqualTo(600));
    });
  });
}
