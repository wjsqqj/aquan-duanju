import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  group('HistoryEntry / FollowEntry 序列化', () {
    test('HistoryEntry 往返', () {
      final e = HistoryEntry(
        seriesId: 's1',
        title: '测试剧',
        coverUrl: 'https://cdn.example.com/x.jpg',
        episode: 5,
        episodes: 80,
        episodeId: 'e5',
        position: 123.5,
        finished: false,
        updatedAt: DateTime.parse('2026-10-28T08:00:00.000'),
      );
      final back = HistoryEntry.fromJson(e.toJson());
      expect(back.seriesId, 's1');
      expect(back.episode, 5);
      expect(back.position, 123.5);
      expect(back.finished, isFalse);
      expect(back.updatedAt, DateTime.parse('2026-10-28T08:00:00.000'));
    });

    test('FollowEntry 往返与坏状态回落', () {
      final e = FollowEntry(
        seriesId: 's2',
        title: '追的剧',
        state: FollowState.want,
      );
      final back = FollowEntry.fromJson(e.toJson());
      expect(back.state, FollowState.want);

      final broken = FollowEntry.fromJson({
        'series_id': 's3',
        'state': 'no-such-state',
      });
      expect(broken.state, FollowState.watching);
    });
  });

  group('SettingsStore', () {
    test('默认值', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.themeMode, 'system');
      expect(s.defaultQuality, 'best');
      expect(s.defaultSpeed, '1.0');
      expect(s.autoNext, isTrue);
      expect(s.randomFromFirst, isTrue);
    });

    test('写入并读取', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      s.themeMode = 'dark';
      s.defaultQuality = '720p';
      s.autoNext = false;
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      expect(s2.themeMode, 'dark');
      expect(s2.defaultQuality, '720p');
      expect(s2.autoNext, isFalse);
    });
  });

  group('SettingsStore.volume', () {
    test('默认 100，写读回', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.volume, 100.0);
      s.volume = 42.5;
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      expect(s2.volume, 42.5);
    });
  });

  group('SettingsStore.cacheQuality', () {
    test('默认 540p，写入读回', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.cacheQuality, '540p');
      s.cacheQuality = 'best';
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      expect(s2.cacheQuality, 'best');
    });
  });
}
