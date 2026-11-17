import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

Future<HistoryStore> _store(Directory dir) async {
  final store = HistoryStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

Future<void> _record(
  HistoryStore store, {
  required int episode,
  bool finished = false,
  String seriesId = 's1',
}) =>
    store.record(
      seriesId: seriesId,
      title: '剧',
      coverUrl: '',
      episode: episode,
      episodes: 20,
      episodeId: '$seriesId-e$episode',
      position: finished ? 0 : 30,
      finished: finished,
    );

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('watched_episodes');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('整集播完才记入 watchedEpisodes，升序去重', () async {
    final store = await _store(dir);
    await _record(store, episode: 3, finished: true);
    await _record(store, episode: 1, finished: true);
    await _record(store, episode: 2); // 未播完
    await _record(store, episode: 1, finished: true); // 重复

    expect(store.get('s1')!.watchedEpisodes, <int>[1, 3]);
  });

  test('进度回写与偏好写入都不丢已看完集号', () async {
    final store = await _store(dir);
    await _record(store, episode: 2, finished: true);
    await _record(store, episode: 5);
    await store.setPlaybackPrefs(seriesId: 's1', speed: 1.5);
    expect(store.get('s1')!.watchedEpisodes, <int>[2]);
  });

  test('重启后从 JSON 还原', () async {
    final store = await _store(dir);
    await _record(store, episode: 4, finished: true);

    final fresh = await _store(dir);
    expect(fresh.get('s1')!.watchedEpisodes, <int>[4]);

    final Map<String, dynamic> raw = jsonDecode(
      File('${dir.path}${Platform.pathSeparator}aquan_history.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final entry = raw['s1'] as Map<String, dynamic>;
    expect(entry['watched_episodes'], <int>[4]);
  });

  test('旧记录没有 watched_episodes 键：读成空列表且不写脏数据', () async {
    File('${dir.path}${Platform.pathSeparator}aquan_history.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{
      'legacy': <String, dynamic>{
        'series_id': 'legacy',
        'episode': 6,
        'position': 120.0,
        'updated_at': DateTime(2025, 1, 1).toIso8601String(),
      },
    }));

    final store = await _store(dir);
    expect(store.get('legacy')!.watchedEpisodes, isEmpty);
    expect(store.get('legacy')!.episode, 6);

    // 旧记录被回写时也不带空数组（保持文件形状最小）。
    await _record(store, seriesId: 'legacy', episode: 6);
    final Map<String, dynamic> raw = jsonDecode(
      File('${dir.path}${Platform.pathSeparator}aquan_history.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      (raw['legacy'] as Map<String, dynamic>).containsKey('watched_episodes'),
      isFalse,
    );
  });

  test('parseWatchedEpisodes 容错：非法元素忽略、去重升序', () {
    expect(
      HistoryEntry.parseWatchedEpisodes(<dynamic>[3, '2', null, 1, 3, 0, -1]),
      <int>[1, 3],
    );
    expect(HistoryEntry.parseWatchedEpisodes(null), isEmpty);
    expect(HistoryEntry.parseWatchedEpisodes('x'), isEmpty);
  });
}
