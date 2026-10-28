import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // _JsonFileStore 走 path_provider；mock 成一次性临时目录做真实读写往返。
    final dir = Directory.systemTemp.createTempSync('aquan_search_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => dir.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });
  });

  group('SearchHistoryStore', () {
    test('记录新词置顶，重复记录去重并前移', () async {
      final s = SearchHistoryStore();
      await s.record('末世');
      await s.record('穿越');
      await s.record('末世');
      expect(s.queries, ['末世', '穿越']);
    });

    test('空词与纯空白不记录', () async {
      final s = SearchHistoryStore();
      await s.record('');
      await s.record('   ');
      expect(s.queries, isEmpty);
    });

    test('超过上限淘汰最旧的', () async {
      final s = SearchHistoryStore();
      for (var i = 0; i < SearchHistoryStore.maxEntries + 5; i++) {
        await s.record('词$i');
      }
      expect(s.queries.length, SearchHistoryStore.maxEntries);
      expect(s.queries.first, '词${SearchHistoryStore.maxEntries + 4}');
      expect(s.queries.contains('词0'), isFalse);
    });

    test('持久化往返：新实例读回旧数据', () async {
      final first = SearchHistoryStore();
      await first.record('玄机');
      await first.record('修仙');

      final second = SearchHistoryStore();
      await second.ensureLoaded();
      expect(second.queries, ['修仙', '玄机']);
    });

    test('单删与清空', () async {
      final s = SearchHistoryStore();
      await s.record('A');
      await s.record('B');
      await s.remove('A');
      expect(s.queries, ['B']);
      await s.clear();
      expect(s.queries, isEmpty);

      // 清空后再读盘确认已持久化。
      final fresh = SearchHistoryStore();
      await fresh.ensureLoaded();
      expect(fresh.queries, isEmpty);
    });
  });
}
