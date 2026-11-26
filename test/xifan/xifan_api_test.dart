import 'dart:convert';

import 'package:aquan_duanju/core/xifan/xifan_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _searchBody({
  required List<Map<String, dynamic>> voList,
  bool hasMore = false,
}) =>
    {
      'ret': 0,
      'timestamp': 1,
      'result': {
        'elements': [
          {
            'dataType': 'dramaSearchList',
            'contents': [
              for (final vo in voList) {'type': ['duanju'], 'duanjuVo': vo},
            ],
          },
        ],
        'hasMore': hasMore,
      },
    };

Map<String, dynamic> _vo({
  String source = 'tianqiao',
  String duanjuId = 'opo200800',
  String title = '全球厨艺倒退3000年',
  String cover = 'https://xifan.heytapimage.com/a.jpg',
}) =>
    {
      'source': source,
      'duanjuId': duanjuId,
      'title': title,
      'coverImageUrl': cover,
      'desc': '简介',
      'total': 71,
      'categories': ['都市', '逆袭'],
    };

void main() {
  group('XifanApi.search', () {
    test('解析 elements[].contents[].duanjuVo 并标来源', () async {
      final api = XifanApi(
        client: MockClient((request) async {
          expect(request.url.path, '/xifan/search/getSearchList');
          expect(request.url.queryParameters['keyword'], '重生');
          expect(request.url.queryParameters['pageIndex'], '1');
          // 公共版本参数必须带上，否则上游可能拒绝。
          expect(request.url.queryParameters['version'], XifanApi.clientVersion);
          return _json(_searchBody(voList: [_vo()], hasMore: true));
        }),
      );
      final page = await api.search('重生');
      expect(page.items, hasLength(1));
      final item = page.items.first;
      expect(item.source, 'tianqiao');
      expect(item.duanjuId, 'opo200800');
      expect(item.title, '全球厨艺倒退3000年');
      expect(item.seriesId, 'xifan:tianqiao:opo200800');
      expect(item.total, 71);
      expect(item.categories, ['都市', '逆袭']);
      expect(page.hasMore, isTrue);
    });

    test('空关键词不发请求', () async {
      var called = false;
      final api = XifanApi(
        client: MockClient((request) async {
          called = true;
          return _json(_searchBody(voList: const []));
        }),
      );
      final page = await api.search('   ');
      expect(page.items, isEmpty);
      expect(called, isFalse);
    });

    test('ret != 0 抛可读异常', () async {
      final api = XifanApi(
        client: MockClient((request) async => _json({'ret': 500})),
      );
      expect(
        () => api.search('重生'),
        throwsA(isA<XifanException>().having(
            (e) => e.message, 'message', contains('结构异常'))),
      );
    });

    test('结构异常（result 缺失）抛异常', () async {
      final api = XifanApi(
        client: MockClient((request) async => _json({'ret': 0})),
      );
      expect(() => api.search('重生'), throwsA(isA<XifanException>()));
    });

    test('非 200 抛「来源暂不可用」', () async {
      final api = XifanApi(
        client: MockClient((request) async => _json({'ret': 0}, status: 502)),
      );
      expect(
        () => api.search('重生'),
        throwsA(isA<XifanException>()
            .having((e) => e.message, 'message', contains('暂不可用'))),
      );
    });

    test('条目缺少 duanjuId / title 时丢弃', () async {
      final api = XifanApi(
        client: MockClient((request) async => _json(_searchBody(voList: [
              _vo(duanjuId: ''),
              _vo(title: ''),
              _vo(duanjuId: 'ok1', title: '可播'),
            ]))),
      );
      final page = await api.search('重生');
      expect(page.items.map((e) => e.duanjuId), ['ok1']);
    });
  });

  group('XifanApi.detail', () {
    Map<String, dynamic> detailBody({
      List<Map<String, dynamic>>? episodes,
      String source = 'tianqiao',
      String duanjuId = 'opo200800',
    }) =>
        {
          'ret': 0,
          'result': {
            'source': source,
            'duanjuId': duanjuId,
            'title': '全球厨艺倒退3000年',
            'coverImageUrl': 'https://xifan.heytapimage.com/a.jpg',
            'desc': '简介',
            'total': 71,
            'categories': ['都市'],
            'episodeList': episodes ?? const [],
          },
        };

    test('解析 episodeList 并按 index 排序', () async {
      final api = XifanApi(
        client: MockClient((request) async {
          expect(request.url.path, '/xifan/drama/getDuanjuInfo');
          expect(request.url.queryParameters['source'], 'tianqiao');
          return _json(detailBody(episodes: [
            {
              'episodeId': 'ep2',
              'index': 2,
              'title': '第2集',
              'playUrl': 'https://dj.youlishipin.com/v?e=2',
              'unlock': true,
            },
            {
              'episodeId': 'ep1',
              'index': 1,
              'title': '第1集',
              'playUrl': 'https://dj.youlishipin.com/v?e=1',
              'unlock': false,
            },
          ]));
        }),
      );
      final drama = await api.detail('tianqiao', 'opo200800');
      expect(drama.episodes.map((e) => e.index), [1, 2]);
      expect(drama.episodes.first.unlock, isFalse);
      expect(drama.episodes.last.unlock, isTrue);
      expect(drama.seriesId, 'xifan:tianqiao:opo200800');
    });

    test('分集为空时抛「没有返回可用分集」', () async {
      final api = XifanApi(
        client: MockClient((request) async => _json(detailBody())),
      );
      expect(
        () => api.detail('tianqiao', 'opo200800'),
        throwsA(isA<XifanException>()
            .having((e) => e.message, 'message', contains('没有返回可用分集'))),
      );
    });

    test('返回的 duanjuId 与请求不一致时抛异常', () async {
      final api = XifanApi(
        client: MockClient((request) async => _json(detailBody(
              duanjuId: 'other',
              episodes: [
                {
                  'episodeId': 'ep1',
                  'index': 1,
                  'title': '第1集',
                  'playUrl': 'https://x/v?e=1',
                  'unlock': true,
                },
              ],
            ))),
      );
      expect(
        () => api.detail('tianqiao', 'opo200800'),
        throwsA(isA<XifanException>()
            .having((e) => e.message, 'message', contains('不一致'))),
      );
    });

    test('非法编号不发请求', () async {
      var called = false;
      final api = XifanApi(
        client: MockClient((request) async {
          called = true;
          return _json(detailBody());
        }),
      );
      expect(
        () => api.detail('bad id', 'opo200800'),
        throwsA(isA<XifanException>()),
      );
      expect(called, isFalse);
    });
  });

  group('XifanApi.resolvePlayUrl', () {
    test('HEAD 跟随到 mp4 签名地址', () async {
      var sawHead = false;
      final api = XifanApi(
        client: MockClient((request) async {
          sawHead = request.method == 'HEAD';
          return http.Response('', 302, headers: const {
            'location':
                'https://xifan.heytapdownload.com/a/b.mp4?sign=abc&X-Amz-Expires=3600',
          });
        }),
      );
      final url = await api.resolvePlayUrl('https://dj.youlishipin.com/duanju/video302?x=1');
      expect(sawHead, isTrue);
      expect(url, contains('.mp4'));
      expect(url, contains('sign=abc'));
    });

    test('HEAD 失败时回退原地址', () async {
      final api = XifanApi(
        client: MockClient((request) async => http.Response('', 405)),
      );
      const original = 'https://dj.youlishipin.com/duanju/video302?x=1';
      expect(await api.resolvePlayUrl(original), original);
    });

    test('Location 不是 mp4 时也回退原地址', () async {
      final api = XifanApi(
        client: MockClient((request) async => http.Response('', 302, headers: const {
          'location': 'https://example.com/not-a-video',
        })),
      );
      const original = 'https://dj.youlishipin.com/duanju/video302?x=1';
      expect(await api.resolvePlayUrl(original), original);
    });
  });

  group('XifanSearchItem.fromSeriesId', () {
    test('还原 source / duanjuId', () {
      final item = XifanSearchItem.fromSeriesId('xifan:tianqiao:opo200800');
      expect(item, isNotNull);
      expect(item!.source, 'tianqiao');
      expect(item.duanjuId, 'opo200800');
    });

    test('非法 id 返回 null', () {
      expect(XifanSearchItem.fromSeriesId('xifan:tianqiao'), isNull);
      expect(XifanSearchItem.fromSeriesId('hongguo:123'), isNull);
      expect(XifanSearchItem.fromSeriesId('xifan:a b:c'), isNull);
    });
  });
}
