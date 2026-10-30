import 'dart:io';

import 'package:aquan_duanju/core/reader/content_signature.dart';
import 'package:aquan_duanju/core/reader/reader_annotations.dart';
import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:aquan_duanju/core/reader/replace_rules.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('阅读设置新字段', () {
    test('震动与音效往返', () {
      const settings = ReaderSettings(hapticOnTurn: false, soundOnTurn: true);
      final restored = ReaderSettings.fromJson(settings.toJson());
      expect(restored.hapticOnTurn, isFalse);
      expect(restored.soundOnTurn, isTrue);
    });

    test('旧 JSON 缺字段时用默认值', () {
      final restored = ReaderSettings.fromJson(<String, dynamic>{'schema': 2});
      expect(restored.hapticOnTurn, isTrue);
      expect(restored.soundOnTurn, isFalse);
    });
  });

  group('正文指纹', () {
    test('稳定且随内容变化', () {
      const a = '第一章 春江潮水连海平';
      expect(contentSignature(a), contentSignature(a));
      expect(contentSignature(a), hasLength(8));
      expect(contentSignature(a), isNot(contentSignature('$a。')));
    });

    test('空串固定值', () {
      expect(contentSignature(''), '00000000');
    });

    test('段落签名与 join 口径一致', () {
      final paragraphs = <String>['甲', '乙'];
      expect(paragraphsSignature(paragraphs), contentSignature('甲\n乙'));
    });
  });

  group('替换规则', () {
    test('内置 4 条，默认全部启用', () {
      expect(kBuiltinReplaceRules.length, 4);
      expect(kBuiltinReplaceRules.every((r) => r.enabled), isTrue);
    });

    test('去掉网址与推广语', () {
      final out = applyReplaceRules(
        <String>[
          '正文第一段 https://example.com/x',
          '本章未完，请点击下一页继续',
          '正常段落',
        ],
        kBuiltinReplaceRules,
      );
      expect(out.length, 2);
      expect(out.first.contains('http'), isFalse);
      expect(out.any((p) => p.contains('本章未完')), isFalse);
      expect(out.last, '正常段落');
    });

    test('替换后为空的段落被丢弃', () {
      final out = applyReplaceRules(
        <String>['https://a.com', '内容'],
        kBuiltinReplaceRules,
      );
      expect(out, <String>['内容']);
    });

    test('非正则按字面量替换', () {
      final out = applyReplaceRules(
        <String>['a*b*c'],
        <ReplaceRule>[
          const ReplaceRule(
            id: 'x',
            name: '字面',
            pattern: '*',
            replacement: '-',
            isRegex: false,
          ),
        ],
      );
      expect(out.single, 'a-b-c');
    });

    test('作用域过滤：仅本书只对指定书生效', () {
      final rules = <ReplaceRule>[
        const ReplaceRule(
          id: 'a',
          name: '全局',
          pattern: 'x',
          scope: ReplaceScope.global,
        ),
        const ReplaceRule(
          id: 'b',
          name: '本书',
          pattern: 'y',
          scope: ReplaceScope.book,
          bookId: 'book1',
        ),
      ];
      expect(rulesForBook(rules, 'book1').length, 2);
      expect(rulesForBook(rules, 'book2').length, 1);
    });

    test('非法正则被跳过而不是抛异常', () {
      final out = applyReplaceRules(
        <String>['abc'],
        <ReplaceRule>[
          const ReplaceRule(id: 'bad', name: '坏正则', pattern: '([a-'),
        ],
      );
      expect(out.single, 'abc');
      expect(isValidPattern('([a-'), isFalse);
      expect(isValidPattern(r'\d+'), isTrue);
    });
  });

  group('ReplaceRuleStore', () {
    late Directory dir;
    late ReplaceRuleStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('replace_rules');
      store = ReplaceRuleStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('首载即内置规则', () {
      expect(store.rules.length, 4);
      expect(store.rules.every((r) => r.enabled), isTrue);
    });

    test('禁用内置规则可持久化', () async {
      await store.setEnabled('builtin_url', false);
      expect(store.rules.firstWhere((r) => r.id == 'builtin_url').enabled,
          isFalse);
      final reloaded = ReplaceRuleStore(testDirectory: dir);
      await reloaded.ensureLoaded();
      expect(reloaded.rules.firstWhere((r) => r.id == 'builtin_url').enabled,
          isFalse);
    });

    test('删除内置=隐藏，恢复内置后回来', () async {
      await store.remove('builtin_url');
      expect(store.rules.length, 3);
      await store.restoreBuiltin();
      expect(store.rules.length, 4);
    });

    test('新增/编辑/删除自定义规则', () async {
      final rule = await store.add(
        name: '去水印',
        pattern: r'水印\d+',
        replacement: '',
      );
      expect(store.rules.length, 5);
      await store.update(rule.copyWith(name: '去水印2', enabled: false));
      expect(store.rules.last.enabled, isFalse);
      await store.remove(rule.id);
      expect(store.rules.length, 4);
    });

    test('导入按 id 去重', () async {
      final incoming = <String, dynamic>{
        'rules': <Map<String, dynamic>>[
          const ReplaceRule(id: 'r1', name: 'A', pattern: 'a').toJson(),
          const ReplaceRule(id: 'r1', name: 'A2', pattern: 'a2').toJson(),
        ],
      };
      expect(await store.importData(incoming), 1);
      expect(await store.importData(incoming), 0);
    });
  });

  group('书签', () {
    late Directory dir;
    late BookmarkStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bookmarks');
      store = BookmarkStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('新增与去重', () async {
      final first = await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charOffset: 120,
        chapterTitle: '第一章',
        excerpt: '春江潮水',
      );
      final again = await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charOffset: 120,
      );
      expect(again.id, first.id);
      expect(store.countOf('b1'), 1);
    });

    test('按章号与偏移排序', () async {
      await store.add(
          bookId: 'b1', chapterId: 'c2', chapterIndex: 1, charOffset: 10);
      await store.add(
          bookId: 'b1', chapterId: 'c1', chapterIndex: 0, charOffset: 90);
      await store.add(
          bookId: 'b1', chapterId: 'c1', chapterIndex: 0, charOffset: 5);
      final list = store.of('b1');
      expect(list.map((b) => b.charOffset).toList(), <int>[5, 90, 10]);
    });

    test('删除与持久化往返', () async {
      final bookmark = await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charOffset: 30,
        excerpt: '摘录',
      );
      final reloaded = BookmarkStore(testDirectory: dir);
      await reloaded.ensureLoaded();
      expect(reloaded.of('b1').single.excerpt, '摘录');
      await reloaded.remove('b1', bookmark.id);
      expect(reloaded.of('b1'), isEmpty);
    });

    test('备注更新', () async {
      final bookmark = await store.add(
          bookId: 'b1', chapterId: 'c1', chapterIndex: 0, charOffset: 1);
      await store.updateNote('b1', bookmark.id, '想法');
      expect(store.of('b1').single.note, '想法');
    });
  });

  group('划线', () {
    late Directory dir;
    late MarkingStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('markings');
      store = MarkingStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('区间重叠判定', () {
      final marking = ReaderMarking(
        id: 'm',
        bookId: 'b',
        chapterId: 'c',
        chapterIndex: 0,
        charStart: 10,
        charEnd: 20,
        text: 'x',
        createdAt: DateTime(2026),
      );
      expect(marking.overlaps(0, 11), isTrue);
      expect(marking.overlaps(19, 30), isTrue);
      expect(marking.overlaps(20, 30), isFalse);
      expect(marking.overlaps(0, 10), isFalse);
    });

    test('新增后按章内起点排序，持久化往返', () async {
      await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charStart: 50,
        charEnd: 60,
        text: '后半',
      );
      await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charStart: 5,
        charEnd: 9,
        text: '前半',
      );
      expect(store.of('b1').map((m) => m.charStart).toList(), <int>[5, 50]);

      final reloaded = MarkingStore(testDirectory: dir);
      await reloaded.ensureLoaded();
      expect(reloaded.inChapter('b1', 'c1').length, 2);
    });

    test('空区间不入库', () async {
      final result = await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charStart: 5,
        charEnd: 5,
        text: '',
      );
      expect(result, isNull);
      expect(store.countOf('b1'), 0);
    });
  });

  group('阅读进度', () {
    late Directory dir;
    late ReadingProgressStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reading');
      store = ReadingProgressStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> record({
      required double offset,
      required int charOffset,
      required int revision,
    }) =>
        store.record(
          bookId: 'b1',
          title: '书',
          coverUrl: '',
          chapterId: 'c1',
          chapterTitle: '第一章',
          chapterIndex: 1,
          chapters: 10,
          offset: offset,
          charOffset: charOffset,
          revision: revision,
        );

    test('字符偏移随记录落盘', () async {
      await record(offset: 0.3, charOffset: 456, revision: 1);
      expect(store.entry('b1')!.charOffset, 456);
      final reloaded = ReadingProgressStore(testDirectory: dir);
      await reloaded.ensureLoaded();
      expect(reloaded.entry('b1')!.charOffset, 456);
    });

    test('旧 revision 的写入被丢弃', () async {
      await record(offset: 0.5, charOffset: 900, revision: 5);
      await record(offset: 0.1, charOffset: 10, revision: 3);
      expect(store.entry('b1')!.charOffset, 900);
      expect(store.entry('b1')!.offset, closeTo(0.5, 1e-9));
    });

    test('相同 revision 也丢弃（避免重复写）', () async {
      await record(offset: 0.5, charOffset: 900, revision: 5);
      await record(offset: 0.2, charOffset: 20, revision: 5);
      expect(store.entry('b1')!.charOffset, 900);
    });

    test('旧记录没有 char_offset 时回退 -1', () async {
      await store.record(
        bookId: 'b2',
        title: '旧',
        coverUrl: '',
        chapterId: 'c',
        chapterTitle: 'c',
        chapterIndex: 0,
        chapters: 1,
        offset: 0.2,
      );
      expect(store.entry('b2')!.charOffset, -1);
    });
  });

  group('章节缓存签名', () {
    late Directory dir;
    late BookChapterCache cache;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('chapter_cache');
      cache = BookChapterCache(testDirectory: dir);
      await cache.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('签名不一致视为未命中', () async {
      await cache.put('c1', '正文', signature: 'aabbccdd');
      expect(cache.text('c1'), '正文');
      expect(cache.text('c1', expectSignature: 'aabbccdd'), '正文');
      expect(cache.text('c1', expectSignature: '00000000'), isNull);
      expect(cache.signatureOf('c1'), 'aabbccdd');
    });

    test('旧版本无签名时不校验', () async {
      await cache.put('c2', '正文');
      expect(cache.text('c2', expectSignature: 'deadbeef'), '正文');
      expect(cache.signatureOf('c2'), '');
    });
  });
}
