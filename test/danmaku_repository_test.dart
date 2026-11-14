import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/danmaku/danmaku_repository.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只覆盖 listDanmaku 的假门面：页表按「cursor|startMs」键索引，
/// 可注入「第 N 次调用起抛错」模拟网络故障。
class _ScriptedDanmakuApi extends AquaApi {
  _ScriptedDanmakuApi() : super(_StubClient());

  final Map<String, DanmakuPage> pages = <String, DanmakuPage>{};
  final List<String> calls = <String>[];

  /// 从第几次调用开始抛错（1 起）；null 表示不抛。
  Object? throwFromCall;

  @override
  Future<DanmakuPage> listDanmaku(
    String seriesId,
    String episodeId, {
    int startMs = 0,
    String cursor = '',
    int pageSize = 0,
  }) async {
    calls.add('$cursor|$startMs');
    if (throwFromCall != null && calls.length >= 2) {
      throw throwFromCall!;
    }
    return pages['$cursor|$startMs'] ??
        const DanmakuPage(items: [], hasMore: false);
  }
}

class _StubClient implements AquaClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

DanmakuItem item(String id, int offsetMs, [String? text]) =>
    DanmakuItem(id: id, text: text ?? '弹幕$id', offsetMs: offsetMs);

void main() {
  test('翻页翻到 hasMore=false 合并全集，二次 load 走缓存不再发请求', () async {
    final api = _ScriptedDanmakuApi()
      ..pages.addAll({
        '|60000': DanmakuPage(
            items: [item('a', 61000)],
            startMs: 60000,
            endMs: 90000,
            hasMore: true,
            cursor: 'c1'),
        'c1|0': DanmakuPage(
            items: [item('b', 95000)],
            startMs: 90000,
            endMs: 120000,
            hasMore: true,
            cursor: 'c2'),
        'c2|0': DanmakuPage(
            items: [item('c', 125000)],
            startMs: 120000,
            endMs: 150000,
            hasMore: false),
      });
    final repo = DanmakuRepository(api);

    final first = await repo.load('s1', 'e1', 60000);
    expect(first.map((d) => d.id), ['a', 'b', 'c']);
    expect(api.calls, hasLength(3));

    // 覆盖区内再拉：走缓存。
    final second = await repo.load('s1', 'e1', 100000);
    expect(second.map((d) => d.id), ['a', 'b', 'c']);
    expect(api.calls, hasLength(3));
  });

  test('空页但 hasMore=true 继续翻，不提前截断', () async {
    final api = _ScriptedDanmakuApi()
      ..pages.addAll({
        '|0': const DanmakuPage(
            items: [], startMs: 0, endMs: 30000, hasMore: true, cursor: 'w1'),
        'w1|0': DanmakuPage(
            items: [item('x', 35000)],
            startMs: 30000,
            endMs: 60000,
            hasMore: false),
      });
    final repo = DanmakuRepository(api);

    final out = await repo.load('s1', 'e1', 0);
    expect(out.map((d) => d.id), ['x']);
    expect(api.calls, hasLength(2));
  });

  test('中途失败静默截断：返回已到手的部分，不抛错', () async {
    final api = _ScriptedDanmakuApi()
      ..pages.addAll({
        '|0': DanmakuPage(
            items: [item('a', 1000)],
            startMs: 0,
            endMs: 30000,
            hasMore: true,
            cursor: 'c1'),
        // 第二页不放进页表 → 无脚本，但先注入抛错。
      })
      ..throwFromCall = StateError('网络断了');
    final repo = DanmakuRepository(api);

    final out = await repo.load('s1', 'e1', 0);
    expect(out.map((d) => d.id), ['a']);
  });

  test('seek 越过覆盖区从新位置重拉并合并；覆盖区内不重拉', () async {
    final api = _ScriptedDanmakuApi()
      ..pages.addAll({
        '|60000': DanmakuPage(
            items: [item('a', 61000)],
            startMs: 60000,
            endMs: 90000,
            hasMore: false),
        '|120000': DanmakuPage(
            items: [item('b', 121000)],
            startMs: 120000,
            endMs: 150000,
            hasMore: false),
      });
    final repo = DanmakuRepository(api);

    await repo.load('s1', 'e1', 60000);
    // 覆盖区内（60000~90000±5s 容忍之外但 100000 > 95000）→ 触发重拉。
    final far = await repo.load('s1', 'e1', 120000);
    expect(far.map((d) => d.id), ['a', 'b']);
    // 覆盖区已扩展到 150000：回到 130000 不再发请求。
    final near = await repo.load('s1', 'e1', 130000);
    expect(near.map((d) => d.id), ['a', 'b']);
    expect(api.calls, ['|60000', '|120000']);
  });

  test('drop 丢弃缓存：下次 load 重新翻页', () async {
    final api = _ScriptedDanmakuApi()
      ..pages.addAll({
        '|0': DanmakuPage(
            items: [item('a', 1000)],
            startMs: 0,
            endMs: 30000,
            hasMore: false),
      });
    final repo = DanmakuRepository(api);

    await repo.load('s1', 'e1', 0);
    repo.drop('e1');
    await repo.load('s1', 'e1', 0);
    expect(api.calls, hasLength(2));
  });
}
