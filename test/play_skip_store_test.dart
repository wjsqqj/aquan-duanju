import 'dart:io';

import 'package:aquan_duanju/models/play_skip.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_skip_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  group('PlaySkipEntry', () {
    test('归一化与解析', () {
      expect(PlaySkipEntry.normalize(-1), 0);
      expect(PlaySkipEntry.normalize(999999999), 0);

      final e = PlaySkipEntry.tryFromJson({
        'opening_ms': 15000,
        'ending_ms': -5,
        'updated_at': 123,
      });
      expect(e!.openingMs, 15000);
      expect(e.endingMs, 0);
      expect(e.updatedAt, 123);

      expect(PlaySkipEntry.tryFromJson({'opening_ms': 'bad'}), isNull);
      expect(const PlaySkipEntry().isEmpty, isTrue);
    });

    test('JSON 往返', () {
      const e = PlaySkipEntry(openingMs: 1000, endingMs: 2000, updatedAt: 3);
      final back = PlaySkipEntry.tryFromJson(e.toJson());
      expect(back, e);
    });
  });

  group('PlaySkipStore', () {
    test('upsert / 持久化 / export / import', () async {
      final store = PlaySkipStore();
      await store.upsert(
          's1', const PlaySkipEntry(openingMs: 30000, endingMs: 60000));
      expect(store.entryFor('s1')!.openingMs, 30000);
      expect(store.entryFor('s1')!.updatedAt, greaterThan(0));

      final fresh = PlaySkipStore();
      await fresh.ensureLoaded();
      expect(fresh.entryFor('s1')!.endingMs, 60000);

      final export = await fresh.exportData();
      expect(export['items'], isA<Map>());

      final target = PlaySkipStore();
      await target.ensureLoaded();
      expect(await target.importData(export), 1);
      expect(target.entryFor('s1')!.openingMs, 30000);
    });

    test('空值等同于移除；clear 清空', () async {
      final store = PlaySkipStore();
      await store.upsert('s1', const PlaySkipEntry(openingMs: 1000));
      await store.upsert('s1', const PlaySkipEntry());
      expect(store.entryFor('s1'), isNull);

      await store.upsert('s2', const PlaySkipEntry(endingMs: 1000));
      await store.clear();
      expect(store.entryFor('s2'), isNull);
    });

    test('导入取 updatedAt 较新者', () async {
      final store = PlaySkipStore();
      await store.upsert('s1', const PlaySkipEntry(openingMs: 1000));
      final older = await store.exportData();
      final olderEntry =
          (older['items'] as Map)['s1'] as Map<String, dynamic>;
      olderEntry['updated_at'] = 1;

      await store.upsert('s1', const PlaySkipEntry(openingMs: 9000));
      await store.importData(older);
      expect(store.entryFor('s1')!.openingMs, 9000);
    });
  });
}
