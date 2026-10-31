import 'package:aquan_duanju/core/reader/speech/listen_bookmarks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 听书书签：按书存、新的在前、上限 50、坏数据不拖垮整表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  ListenBookmark mark(String id, {int chapter = 0, int ms = 1000, int at = 1}) =>
      ListenBookmark(
        id: id,
        chapterIndex: chapter,
        chapterTitle: '第 ${chapter + 1} 章',
        positionMs: ms,
        createdAt: at,
      );

  test('add 后能读回；按 createdAt 新的在前', () async {
    final store = ListenBookmarks(prefs);
    await store.add('b1', mark('a', at: 100));
    await store.add('b1', mark('b', at: 200));

    final list = store.of('b1');
    expect(list.map((m) => m.id).toList(), <String>['b', 'a']);
  });

  test('按书隔离：不同书的书签互不影响', () async {
    final store = ListenBookmarks(prefs);
    await store.add('b1', mark('a'));
    await store.add('b2', mark('b'));

    expect(store.of('b1').single.id, 'a');
    expect(store.of('b2').single.id, 'b');
    expect(store.of('b3'), isEmpty);
  });

  test('remove 只删指定 id；clear 清整本', () async {
    final store = ListenBookmarks(prefs);
    await store.add('b1', mark('a', at: 1));
    await store.add('b1', mark('b', at: 2));

    await store.remove('b1', 'a');
    expect(store.of('b1').single.id, 'b');

    await store.clear('b1');
    expect(store.of('b1'), isEmpty);
  });

  test('每本最多 50 条，超出丢最旧的', () async {
    final store = ListenBookmarks(prefs);
    for (var i = 0; i < ListenBookmarks.perBookLimit + 5; i++) {
      await store.add('b1', mark('m$i', at: i));
    }

    final list = store.of('b1');
    expect(list.length, ListenBookmarks.perBookLimit);
    expect(list.first.id, 'm54', reason: '最新的在最前');
    expect(
      list.any((m) => m.id == 'm0'),
      isFalse,
      reason: '最旧的已被挤掉',
    );
  });

  test('键不以 listen. 开头：不应被「恢复默认」清掉', () {
    expect(ListenBookmarks.storageKey.startsWith('listen.'), isFalse);
    expect(ListenBookmarks.storageKey, 'listenmark.bookmarks');
  });

  test('坏 JSON 当空；单条坏条目被跳过', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ListenBookmarks.storageKey: 'not json',
    });
    final broken = ListenBookmarks(await SharedPreferences.getInstance());
    expect(broken.of('b1'), isEmpty);

    // 一条合法 + 一条缺字段
    SharedPreferences.setMockInitialValues(<String, Object>{
      ListenBookmarks.storageKey:
          '{"b1":[{"id":"ok","chapterIndex":1,"positionMs":500,"createdAt":7},'
          '{"chapterIndex":9}]}',
    });
    final mixed = ListenBookmarks(await SharedPreferences.getInstance());
    final list = mixed.of('b1');
    expect(list, hasLength(1));
    expect(list.single.id, 'ok');
  });

  test('tryParse：负位置夹到 0，缺 createdAt 当 0', () {
    final parsed = ListenBookmark.tryParse(<String, dynamic>{
      'id': 'x',
      'chapterIndex': 2,
      'positionMs': -50,
      'chapterTitle': '第三章',
    });
    expect(parsed, isNotNull);
    expect(parsed!.positionMs, 0);
    expect(parsed.createdAt, 0);
    expect(parsed.chapterTitle, '第三章');
  });
}
