import 'dart:convert';

import 'package:aquan_duanju/core/search/hongguo_web_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _video({
  Object seriesId = '7636312627630591038',
  String title = '87年：我撑起一个家',
  int episodeCnt = 60,
}) =>
    {
      'doc_type': 23,
      'video_data': {
        'series_id': seriesId,
        'series_title': title,
        'series_cover': 'https://p3-novel.byteimg.com/a.jpg',
        'episode_cnt': episodeCnt,
        'series_intro': '简介',
        'rating': 8.3,
        'category_list': [
          {'category_id': '5891', 'name': '年代'},
          {'category_id': '5899', 'name': '重生逆袭'},
        ],
        'hot_score_data': {'score': 68644668, 'text': '6864万热度'},
      },
    };

Map<String, dynamic> _body({
  required List<Map<String, dynamic>> list,
  int pageNum = 1,
  int totalPages = 1,
  bool? hasMore,
}) =>
    {
      'searchList': list,
      'totalCount': '218',
      'pageNum': pageNum,
      'totalPages': totalPages,
      'hasMore': ?hasMore,
    };

void main() {
  group('HongguoWebSearch.search', () {
    test('解析 searchList[].video_data 并映射成 SeriesSummary', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async {
          expect(request.url.path, '/api/search/result');
          expect(request.url.queryParameters['aid'], '8662');
          expect(request.url.queryParameters['query'], '重生');
          expect(request.url.queryParameters['page'], '1');
          expect(request.headers['Referer'], isNotNull);
          return _json(_body(list: [_video()]));
        }),
      );
      final page = await search.search('重生');
      expect(page.items, hasLength(1));
      final item = page.items.first;
      expect(item.id, '7636312627630591038');
      expect(item.title, '87年：我撑起一个家');
      expect(item.episodeCount, 60);
      expect(item.heat, 68644668);
      expect(item.score, '8.3');
      expect(item.tags, ['年代', '重生逆袭']);
      // 官网结果必须走现有红果详情：kind 留空。
      expect(item.kind, '');
      expect(page.hasMore, isFalse);
    });

    test('series_id 不是纯数字时丢弃（防止把非剧集塞进详情页）', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async => _json(_body(list: [
              _video(seriesId: 'abc'),
              _video(seriesId: '12'),
              _video(seriesId: '7709153171259542553', title: '正常'),
            ]))),
      );
      final page = await search.search('重生');
      expect(page.items.map((e) => e.id), ['7709153171259542553']);
    });

    test('重复 series_id 只留一条', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async =>
            _json(_body(list: [_video(), _video(title: '重复')]))),
      );
      final page = await search.search('重生');
      expect(page.items, hasLength(1));
    });

    test('分页：cursor 带 web: 前缀，hasMore 由 totalPages 推导', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async => _json(
            _body(list: [_video()], pageNum: 1, totalPages: 22))),
      );
      final page = await search.search('重生');
      expect(page.hasMore, isTrue);
      expect(page.cursor, 'web:2');
      expect(HongguoWebSearch.pageOfCursor(page.cursor), 2);
    });

    test('末页 cursor 为空', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async =>
            _json(_body(list: [_video()], pageNum: 22, totalPages: 22))),
      );
      final page = await search.search('重生', page: 22);
      expect(page.hasMore, isFalse);
      expect(page.cursor, isEmpty);
    });

    test('空 searchList 视为空页（不是错误）', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async => _json(_body(list: const []))),
      );
      final page = await search.search('不存在的剧');
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('空关键词不发请求', () async {
      var called = false;
      final search = HongguoWebSearch(
        client: MockClient((request) async {
          called = true;
          return _json(_body(list: const []));
        }),
      );
      final page = await search.search('   ');
      expect(page.items, isEmpty);
      expect(called, isFalse);
    });

    test('非 200 抛异常', () async {
      final search = HongguoWebSearch(
        client: MockClient(
            (request) async => _json(const <String, dynamic>{}, status: 404)),
      );
      expect(
        () => search.search('重生'),
        throwsA(isA<HongguoWebSearchException>()),
      );
    });

    test('返回体不是 JSON 对象时抛异常', () async {
      final search = HongguoWebSearch(
        client: MockClient((request) async => http.Response('<html>', 200)),
      );
      expect(
        () => search.search('重生'),
        throwsA(isA<HongguoWebSearchException>()),
      );
    });

    test('pageOfCursor 只认 web: 前缀', () {
      expect(HongguoWebSearch.pageOfCursor('web:3'), 3);
      expect(HongguoWebSearch.pageOfCursor('web:x'), isNull);
      expect(HongguoWebSearch.pageOfCursor('abc'), isNull);
    });
  });
}
