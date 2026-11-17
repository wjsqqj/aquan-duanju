import 'package:aquan_duanju/core/search/season_order.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Season season(String id, int index, int episodes) => Season(
      seriesId: id,
      title: '第$index季',
      index: index,
      episodeCount: episodes,
    );

void main() {
  group('nextPlayableSeason（连播跨季）', () {
    final seasons = [
      season('s1', 1, 10),
      season('s2', 2, 12),
      season('s3', 3, 0),
      season('s4', 4, 8),
    ];

    test('本季播完找下一可播季，跳过未上线季', () {
      expect(nextPlayableSeason(seasons, 's1')?.seriesId, 's2');
      expect(nextPlayableSeason(seasons, 's2')?.seriesId, 's4');
    });

    test('最后一季没有下一季', () {
      expect(nextPlayableSeason(seasons, 's4'), isNull);
    });

    test('当前 id 不在合集里不猜（避免跳错剧）', () {
      expect(nextPlayableSeason(seasons, 'unknown'), isNull);
    });

    test('空列表 / 单季 / 空 id 都返回 null', () {
      expect(nextPlayableSeason(const [], 's1'), isNull);
      expect(nextPlayableSeason([season('s1', 1, 3)], 's1'), isNull);
      expect(nextPlayableSeason(seasons, ''), isNull);
    });

    test('hasNextPlayableSeason 与 nextPlayableSeason 口径一致', () {
      expect(hasNextPlayableSeason(seasons, 's1'), isTrue);
      expect(hasNextPlayableSeason(seasons, 's4'), isFalse);
      expect(hasNextPlayableSeason(const [], 's1'), isFalse);
    });
  });
}
