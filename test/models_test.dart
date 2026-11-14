import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/models/models.dart';

void main() {
  group('SeriesSummary', () {
    test('解析完整字段', () {
      final s = SeriesSummary.fromJson(const {
        'id': '7123456789012345678',
        'title': '全球死考',
        'description': '一部测试短剧',
        'cover_url': 'https://cdn.example.com/cover.jpg',
        'cover_expires_at': '2026-10-28T00:00:00Z',
        'episode_count': 80,
        'category': '都市',
        'words': 120000,
      });
      expect(s.id, '7123456789012345678');
      expect(s.title, '全球死考');
      expect(s.episodeCount, 80);
      expect(s.category, '都市');
    });

    test('字段缺失取零值', () {
      final s = SeriesSummary.fromJson(const {'id': '1'});
      expect(s.title, '');
      expect(s.episodeCount, 0);
      expect(s.coverUrl, '');
    });
  });

  group('Series', () {
    test('演员行取 InfoKind=33', () {
      final s = Series.fromJson(const {
        'id': '1',
        'rows': [
          {'kind': 3, 'text': '末世', 'schema': ''},
          {'kind': 33, 'text': '演员·张三 李四', 'schema': ''},
        ],
      });
      expect(s.actorLine, '演员·张三 李四');
    });

    test('novel 可空', () {
      final s = Series.fromJson(const {'id': '1'});
      expect(s.novel, isNull);
      final s2 = Series.fromJson(const {
        'id': '1',
        'novel': {'book_id': 'b1', 'title': '原著'},
      });
      expect(s2.novel?.bookId, 'b1');
    });
  });

  group('PlaybackResult', () {
    test('解密密钥与流', () {
      final r = PlaybackResult.fromJson(const {
        'playback': {
          'episode_id': 'e1',
          'duration_seconds': 120,
          'protected': true,
          'streams': [
            {
              'definition': '720p',
              'width': 720,
              'height': 1280,
              'url': 'https://cdn.example.com/v.m3u8',
              'hls': true,
              'protected': true,
              'encryption': 'cenc-aes-ctr',
            },
            {
              'definition': '1080p',
              'height': 1920,
              'url': 'https://cdn.example.com/v2.m3u8',
              'hls': true,
            },
          ],
        },
        'contentKey': {'key': 'aabbccdd', 'version': '1'},
      });
      expect(r.playback.protected, isTrue);
      expect(r.playback.streams, hasLength(2));
      expect(r.contentKey?.key, 'aabbccdd');
    });

    test('无密钥也不崩', () {
      final r = PlaybackResult.fromJson(const {
        'playback': {'episode_id': 'e1', 'streams': []},
      });
      expect(r.contentKey, isNull);
      expect(r.playback.streams, isEmpty);
    });

    test('contentKeyError 报警信封被透传', () {
      final r = PlaybackResult.fromJson(const {
        'playback': {'episode_id': 'e1', 'protected': true, 'streams': []},
        'contentKeyError': {
          'code': 'DRM_PROTECTED',
          'message': 'drm: unrecognized key material',
        },
      });
      expect(r.contentKey, isNull);
      expect(r.contentKeyError, isNotNull);
      expect(r.contentKeyError!.code, 'DRM_PROTECTED');
      expect(r.contentKeyError!.message, contains('unrecognized'));
      expect(r.contentKeyError!.isEmpty, isFalse);
    });

    test('contentKeyError 缺失时为 null 且不崩', () {
      final r = PlaybackResult.fromJson(const {
        'playback': {'episode_id': 'e1', 'streams': []},
      });
      expect(r.contentKeyError, isNull);
    });
  });

  group('DanmakuPage', () {
    test('正常解析：条目、窗口、总数、游标', () {
      final p = DanmakuPage.fromJson(const {
        'items': [
          {'id': '1', 'text': '前方高能', 'offset_ms': 329, 'likes': 15},
          {'id': '2', 'text': '哈哈', 'offset_ms': 12500},
        ],
        'start_ms': 0,
        'end_ms': 30000,
        'total': 8093,
        'has_more': true,
        'cursor': 'c1',
      });
      expect(p.items, hasLength(2));
      expect(p.items.first.text, '前方高能');
      expect(p.items.first.offsetMs, 329);
      expect(p.items.first.likes, 15);
      expect(p.endMs, 30000);
      expect(p.total, 8093);
      expect(p.hasMore, isTrue);
      expect(p.cursor, 'c1');
    });

    test('缺字段与空列表容错', () {
      final p = DanmakuPage.fromJson(const {
        'items': [
          {'id': '1'},
          {'text': '缺 id'},
          'not-a-map',
        ],
      });
      expect(p.items, hasLength(2));
      expect(p.items.first.offsetMs, 0);
      expect(p.items.first.text, '');
      expect(p.startMs, 0);
      expect(p.hasMore, isFalse);
      expect(p.cursor, '');
    });
  });

  group('分页', () {
    test('AquaPage 解析 items/cursor/has_more', () {
      final p = AquaPage.fromJson<SeriesSummary>(const {
        'items': [
          {'id': 'a', 'title': '剧A'},
          {'id': 'b', 'title': '剧B'},
        ],
        'cursor': 'next-token',
        'has_more': true,
      }, SeriesSummary.fromJson);
      expect(p.items, hasLength(2));
      expect(p.cursor, 'next-token');
      expect(p.hasMore, isTrue);
    });

    test('items 缺省为空', () {
      final p = AquaPage.fromJson<SeriesSummary>(
          const {}, SeriesSummary.fromJson);
      expect(p.items, isEmpty);
    });
  });

  group('榜单', () {
    test('ShortRanking contents 与 items', () {
      final r = ShortRanking.fromJson(const {
        'contents': [
          {
            'id': 'all',
            'name': '全部',
            'selected': true,
            'boards': [
              {'id': 'hot', 'name': '热播榜', 'selected': true},
            ],
          },
        ],
        'content': 'all',
        'board': 'hot',
        'items': [
          {
            'rank': 1,
            'position': 1,
            'title': '榜一剧',
            'series_id': 's1',
            'score': '2550万热度',
            'change': {'kind': 1, 'places': 3},
          },
        ],
        'has_more': false,
      });
      expect(r.contents.single.name, '全部');
      expect(r.items.single.change?.kind, 1);
      expect(r.items.single.score, '2550万热度');
    });
  });

  group('热搜', () {
    test('HotSearch guesses/boards/topics', () {
      final h = HotSearch.fromJson(const {
        'guesses': [
          {'series_id': 'g1', 'title': '猜你搜', 'position': 1},
        ],
        'boards': [
          {
            'name': '短剧热搜榜',
            'items': [
              {'series_id': 'h1', 'title': '热剧', 'position': 1, 'heat': '355万'},
            ],
            'topics': [
              {'id': 't1', 'title': '话题', 'query': '话题搜索', 'heat': '1亿'},
            ],
          },
        ],
      });
      expect(h.guesses.single.seriesId, 'g1');
      expect(h.boards.single.items.single.heat, '355万');
      expect(h.boards.single.topics.single.query, '话题搜索');
    });
  });
}
