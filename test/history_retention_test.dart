import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> record(HistoryStore store, String id) async {
  await store.record(
    seriesId: id,
    title: id,
    coverUrl: '',
    episode: 1,
    episodes: 1,
    episodeId: '$id-e1',
    position: 10,
    finished: false,
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_history_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  test('超过上限淘汰最旧并持久化', () async {
    final store = HistoryStore()..limit = 3;
    for (var i = 1; i <= 5; i++) {
      await record(store, 's$i');
    }
    expect(store.entries.length, 3);
    expect(store.get('s1'), isNull);
    expect(store.get('s5'), isNotNull);

    final fresh = HistoryStore()..limit = 3;
    await fresh.ensureLoaded();
    expect(fresh.entries.length, 3);
    expect(fresh.get('s1'), isNull);
  });

  test('applyLimit 立即裁剪并落盘', () async {
    final store = HistoryStore()..limit = 5;
    for (var i = 1; i <= 4; i++) {
      await record(store, 's$i');
    }
    await store.applyLimit(2);
    expect(store.entries.length, 2);

    final fresh = HistoryStore();
    await fresh.ensureLoaded();
    expect(fresh.entries.length, 2);
  });

  test('进度回写不覆盖手动清晰度 / 倍速偏好', () async {
    final store = HistoryStore();
    await store.setPlaybackPrefs(
        seriesId: 's1', speed: 1.5, quality: '720p');
    await store.record(
      seriesId: 's1',
      title: '剧',
      coverUrl: '',
      episode: 2,
      episodes: 10,
      episodeId: 's1-e2',
      position: 30,
      finished: false,
      speed: 1.5,
      quality: '',
    );
    expect(store.get('s1')!.quality, '720p');
    expect(store.get('s1')!.speed, 1.5);
  });

  test('导入后同样裁剪', () async {
    final store = HistoryStore()..limit = 2;
    await record(store, 'keep');
    await store.importData({
      'old1': {
        'series_id': 'old1',
        'updated_at': DateTime(2000).toIso8601String(),
      },
      'old2': {
        'series_id': 'old2',
        'updated_at': DateTime(2001).toIso8601String(),
      },
    });
    expect(store.entries.length, 2);
    expect(store.get('old1'), isNull);
  });
}
