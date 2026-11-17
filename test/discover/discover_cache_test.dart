import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/store/discover_cache.dart';
import 'package:flutter_test/flutter_test.dart';

SeriesSummary _series(int i) => SeriesSummary(
      id: 's$i',
      title: '剧$i',
      coverUrl: 'https://example.com/$i.jpg',
      coverExpiresAt: '2027-01-01',
      episodeCount: i + 1,
      heat: i * 10,
      playCount: i * 100,
      tags: const ['古装'],
    );

void main() {
  late Directory dir;
  late DiscoverCacheStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('discover_cache');
    store = DiscoverCacheStore(directory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File cacheFile() =>
      File('${dir.path}${Platform.pathSeparator}${DiscoverCacheStore.fileName}');

  test('保存后可原样读回（含角标）', () async {
    await store.save(DiscoverSnapshot(
      typeKey: 'drama',
      channelKey: 'drama|recommend',
      savedAtMs: 1700000000000,
      items: [_series(1), _series(2)],
      badges: const {'s1': '1', 's2': '广告'},
    ));

    final loaded = await store.load(
      typeKey: 'drama',
      channelKey: 'drama|recommend',
    );
    expect(loaded, isNotNull);
    expect(loaded!.items.map((e) => e.id), ['s1', 's2']);
    expect(loaded.items.first.title, '剧1');
    expect(loaded.items.first.coverExpiresAt, '2027-01-01');
    expect(loaded.items.first.tags, ['古装']);
    expect(loaded.badges['s1'], '1');
    expect(loaded.savedAtMs, 1700000000000);
  });

  test('类型/频道不匹配视为未命中', () async {
    await store.save(DiscoverSnapshot(
      typeKey: 'drama',
      channelKey: 'drama|recommend',
      savedAtMs: 1,
      items: [_series(1)],
    ));
    expect(
      await store.load(typeKey: 'novel', channelKey: 'drama|recommend'),
      isNull,
    );
    expect(
      await store.load(typeKey: 'drama', channelKey: 'drama|hot'),
      isNull,
    );
  });

  test('超过 48 条只留前 48 条，角标同步裁剪', () async {
    final items = [for (var i = 0; i < 60; i++) _series(i)];
    await store.save(DiscoverSnapshot(
      typeKey: 'drama',
      channelKey: 'c',
      savedAtMs: 1,
      items: items,
      badges: {for (final item in items) item.id: '1'},
    ));
    final loaded =
        await store.load(typeKey: 'drama', channelKey: 'c');
    expect(loaded!.items.length, DiscoverCacheStore.maxItems);
    expect(loaded.items.last.id, 's47');
    expect(loaded.badges.length, DiscoverCacheStore.maxItems);
  });

  test('坏 JSON / 空文件 / 不存在都返回 null', () async {
    expect(await store.load(typeKey: 'drama', channelKey: 'c'), isNull);

    cacheFile().writeAsStringSync('{not json');
    expect(await store.load(typeKey: 'drama', channelKey: 'c'), isNull);

    cacheFile().writeAsStringSync('');
    expect(await store.load(typeKey: 'drama', channelKey: 'c'), isNull);
  });

  test('版本号不匹配返回 null', () async {
    cacheFile().writeAsStringSync(jsonEncode(<String, dynamic>{
      'version': 999,
      'type': 'drama',
      'channel': 'c',
      'items': [
        {'id': 'x'},
      ],
    }));
    expect(await store.load(typeKey: 'drama', channelKey: 'c'), isNull);
  });

  test('clear 删除文件', () async {
    await store.save(DiscoverSnapshot(
      typeKey: 'drama',
      channelKey: 'c',
      savedAtMs: 1,
      items: [_series(1)],
    ));
    expect(cacheFile().existsSync(), isTrue);
    await store.clear();
    expect(cacheFile().existsSync(), isFalse);
  });
}
