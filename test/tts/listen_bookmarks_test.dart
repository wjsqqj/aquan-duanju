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

  test('备注：往返保留，空串不写进 JSON', () async {
    final store = ListenBookmarks(prefs);
    await store.add(
      'b1',
      const ListenBookmark(
        id: 'n1',
        chapterIndex: 0,
        chapterTitle: '第一章',
        positionMs: 1000,
        createdAt: 1,
        note: '这段很关键',
      ),
    );
    await store.add('b1', mark('n2', at: 2));

    final list = store.of('b1');
    expect(list.firstWhere((m) => m.id == 'n1').note, '这段很关键');
    expect(list.firstWhere((m) => m.id == 'n2').note, isEmpty);

    final raw = prefs.getString(ListenBookmarks.storageKey) ?? '';
    expect(raw.contains('"note"'), isTrue);
    // 空备注不该写入：只有一个 note 字段（n1 的）。
    expect('"note"'.allMatches(raw).length, 1);
  });

  test('updateNote：只改目标书签的备注，位置与排序不变', () async {
    final store = ListenBookmarks(prefs);
    await store.add('b1', mark('a', at: 100, ms: 111));
    await store.add('b1', mark('b', at: 200, ms: 222));

    await store.updateNote('b1', 'a', '  补一句  ');

    final list = store.of('b1');
    expect(list.map((m) => m.id).toList(), <String>['b', 'a'], reason: '顺序不变');
    final a = list.firstWhere((m) => m.id == 'a');
    expect(a.note, '补一句', reason: '两端空白被去掉');
    expect(a.positionMs, 111, reason: '位置不受影响');
    expect(list.firstWhere((m) => m.id == 'b').note, isEmpty);
  });

  test('updateNote：不存在的 id 静默返回', () async {
    final store = ListenBookmarks(prefs);
    await store.add('b1', mark('a'));
    await store.updateNote('b1', '不存在', 'x');
    expect(store.of('b1').single.note, isEmpty);
  });

  test('tryParse：缺备注字段当空串', () {
    final parsed = ListenBookmark.tryParse(<String, dynamic>{
      'id': 'x',
      'chapterIndex': 1,
      'positionMs': 10,
    });
    expect(parsed!.note, isEmpty);
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
