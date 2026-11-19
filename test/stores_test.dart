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

  group('SettingsStore 托盘后台', () {
    test('三个设置默认 true/false/true，setter 往返', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.trayOnClose, isTrue);
      expect(s.trayOnMinimize, isFalse);
      expect(s.lightweightOnTray, isTrue);

      s.trayOnClose = false;
      s.trayOnMinimize = true;
      s.lightweightOnTray = false;
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      expect(s2.trayOnClose, isFalse);
      expect(s2.trayOnMinimize, isTrue);
      expect(s2.lightweightOnTray, isFalse);
    });

    test('lightweightActive 默认 false 且不落盘、不进备份', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.lightweightActive, isFalse);
      s.lightweightActive = true;
      expect(s.lightweightActive, isTrue);

      final s2 = SettingsStore(await SharedPreferences.getInstance());
      expect(s2.lightweightActive, isFalse, reason: '运行时状态必须重启回落');
      expect(s.exportBackup().containsKey('desktop.trayOnClose'), isFalse);
      expect(s.exportBackup().containsKey('desktop.trayOnMinimize'), isFalse);
      expect(s.exportBackup().containsKey('desktop.lightweightOnTray'), isFalse);
      expect(
        s.importBackup({
          'desktop.trayOnClose': false,
          'desktop.trayOnMinimize': true,
          'desktop.lightweightOnTray': false,
        }),
        0,
        reason: '机器相关键不随备份导入',
      );
      expect(s.trayOnClose, isTrue);
      expect(s.trayOnMinimize, isFalse);
      expect(s.lightweightOnTray, isTrue);
    });
  });
}
