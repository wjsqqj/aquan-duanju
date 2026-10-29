import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../models/book.dart';
import '../models/models.dart';
import 'aqua_client.dart';

/// fetchImage 的最小接口，便于缓存层与测试注入假实现；[AquaApi] 实现它。
abstract class AquaImageFetcher {
  Future<AquaImage> fetchImage(String url);
}

/// fetchImage 的结果：已经是 Flutter 可直接解码的字节（HEIC 已由核心转成
/// JPEG），mime 是对应类型。
class AquaImage {
  const AquaImage(this.bytes, this.mime);

  final Uint8List bytes;
  final String mime;
}

/// 类型化的 API 门面：把 AquaClient 的动态 JSON 调用包成返回模型的方法。
/// 页面只看这一层，不碰信封与 jsonDecode。
class AquaApi implements AquaImageFetcher {
  AquaApi(this._client);

  final AquaClient _client;

  static final Random _rng = Random();

  /// 下载一张封面图并按需转码（服务端固定返回 HEIC，见核心 image.go）。
  /// 失败抛 AquaException（403 = 签名过期，走裂图占位兜底）。
  @override
  Future<AquaImage> fetchImage(String url) async {
    final r = _map(await _client.call('fetchImage', [url]));
    final data = base64Decode(r['data'] as String? ?? '');
    return AquaImage(data, r['mime'] as String? ?? 'image/jpeg');
  }

  // ---------- 目录 ----------

  /// 发现流（书城频道）。channel 空即推荐。
  Future<AquaPage<SeriesSummary>> discover({String channel = '', String cursor = ''}) async {
    final r = await _client.call('discover', [
      {'channel': channel, 'cursor': cursor},
    ]);
    return AquaPage.fromJson<SeriesSummary>(
        _map(r), SeriesSummary.fromJson);
  }

  /// 搜索。tab 空即综合；filters 收窄综合结果（与游标要一起传）。
  Future<AquaPage<SeriesSummary>> search(
    String query, {
    String cursor = '',
    String tab = '',
    List<String> filters = const [],
    int pageSize = 0,
  }) async {
    final r = await _client.call('search', [
      query,
      {
        'cursor': cursor,
        'tab': tab,
        'filters': filters,
        if (pageSize > 0) 'pageSize': pageSize,
      },
    ]);
    return AquaPage.fromJson<SeriesSummary>(
        _map(r), SeriesSummary.fromJson);
  }

  Future<List<Suggestion>> suggest(String prefix) async {
    final r = await _client.call('suggest', [prefix]);
    return _list(r).map(Suggestion.fromJson).toList();
  }

  Future<HotSearch> hotSearch() async =>
      HotSearch.fromJson(_map(await _client.call('hotSearch')));

  Future<List<String>> searchCues() async =>
      _list(await _client.call('searchCues')).cast<String>();

  Future<NewReleasePage> newReleases({String date = '', String cursor = ''}) async {
    final r = await _client.call('newReleases', [
      {'date': date, 'cursor': cursor},
    ]);
    return NewReleasePage.fromJson(_map(r));
  }

  // ---------- 剧集 ----------

  Future<Series> getSeries(String id) async =>
      Series.fromJson(_map(await _client.call('getSeries', [id])));

  Future<List<SeriesDetail>> getSeriesBatch(List<String> ids) async {
    final r = await _client.call('getSeriesBatch', [ids]);
    return _list(r).map(SeriesDetail.fromJson).toList();
  }

  Future<AquaPage<Episode>> listEpisodes(String seriesId, {String cursor = '', int pageSize = 0}) async {
    final r = await _client.call('listEpisodes', [
      seriesId,
      {'cursor': cursor, if (pageSize > 0) 'pageSize': pageSize},
    ]);
    return AquaPage.fromJson<Episode>(_map(r), Episode.fromJson);
  }

  Future<Album> seasons(String seriesId) async =>
      Album.fromJson(_map(await _client.call('seasons', [seriesId])));

  Future<Recommend> seriesRecommend(String seriesId) async =>
      Recommend.fromJson(_map(await _client.call('seriesRecommend', [seriesId])));

  // ---------- 播放 ----------

  /// 解析播放地址；加密剧集自动带 contentKey（解密交给播放器）。
  Future<PlaybackResult> resolvePlayback(String episodeId) async =>
      PlaybackResult.fromJson(_map(await _client.call('resolvePlayback', [episodeId])));

  // ---------- 榜单与筛选 ----------

  Future<ShortRanking> shortRank({String content = '', String board = '', String cursor = ''}) async {
    final r = await _client.call('shortRank', [
      {'content': content, 'board': board, 'cursor': cursor},
    ]);
    return ShortRanking.fromJson(_map(r));
  }

  Future<List<FilterRow>> shortFilterPanel(String genre) async {
    final r = await _client.call('shortFilterPanel', [genre]);
    return _list(r).map(FilterRow.fromJson).toList();
  }

  Future<ShortFilterPage> shortFilter(
    Map<String, List<String>> selections, {
    String cursor = '',
  }) async {
    final r = await _client.call('shortFilter', [
      {'selections': selections, 'cursor': cursor},
    ]);
    return ShortFilterPage.fromJson(_map(r));
  }

  Future<List<RankContent>> shortRankContents() async {
    final first = await shortRank();
    return first.contents;
  }

  Future<Ranking> ranking(String activityId, String listId) async =>
      Ranking.fromJson(_map(await _client.call('ranking', [activityId, listId])));

  Future<Ranking> rankRows(String cellId, int offset) async =>
      Ranking.fromJson(_map(await _client.call('rankRows', [cellId, offset])));

  Future<List<RankList>> rankGroups() async {
    final r = await _client.call('rankGroups');
    return _list(r).map(RankList.fromJson).toList();
  }

  // ---------- 分类 ----------

  Future<List<String>> categories(String categoryId) async {
    // categories 返回 CategoryPage（分类本身的列表）；详情页分类用的不多，
    // 这里透传 items 的标题。
    final r = await _client.call('categories', [categoryId]);
    final page = CategoryPage.fromJson(_map(r));
    return page.items.map((s) => s.title).toList();
  }

  Future<CategoryPage> categoryLanding(
    String categoryId, {
    String tab = '',
    Map<String, String> filters = const {},
    String cursor = '',
  }) async {
    final r = await _client.call('categoryLanding', [
      categoryId,
      {'tab': tab, 'filters': filters, 'cursor': cursor},
    ]);
    return CategoryPage.fromJson(_map(r));
  }

  // ---------- 人物 ----------

  Future<Person> person(String userId) async =>
      Person.fromJson(_map(await _client.call('person', [userId])));

  Future<WorkPage> personWorks(String userId, {String cursor = ''}) async {
    final r = await _client.call('personWorks', [userId, cursor]);
    return WorkPage.fromJson(_map(r));
  }

  // ---------- 阅读 ----------

  /// 书籍详情（小说频道）。
  Future<BookDetail> bookDetail(String bookId) async =>
      BookDetail.fromJson(_map(await _client.call('bookDetail', [bookId])));

  /// 整本章节目录（不分页）。
  Future<BookDirectory> bookDirectory(String bookId) async =>
      BookDirectory.fromJson(_map(await _client.call('bookDirectory', [bookId])));


  /// 设备的内容密钥（首次调用会注册并落盘 sidecar）。
  Future<String> secretKey() async =>
      (await _client.call('secretKey')) as String? ?? '';

  /// 取一章正文并解密；书籍尚未开放或解密失败时抛 AquaException。
  Future<String> chapterText(String itemId) async {
    final r = _map(await _client.call('chapterText', [itemId]));
    return r['text'] as String? ?? '';
  }

  // ---------- 设备 ----------

  Future<void> resetDevice() => _client.call('resetDevice');

  /// 随机取一部剧的 id：从发现流随机页开始翻。随机播放 feed 的候选来源之一。
  Future<List<SeriesSummary>> randomCandidates({int pages = 2}) async {
    final out = <SeriesSummary>[];
    var cursor = '';
    for (var i = 0; i < pages; i++) {
      final page = await discover(cursor: cursor);
      out.addAll(page.items);
      if (!page.hasMore || page.cursor.isEmpty) break;
      cursor = page.cursor;
    }
    out.shuffle(_rng);
    return out;
  }

  Map<String, dynamic> _map(dynamic v) =>
      v is Map<String, dynamic> ? v : <String, dynamic>{};

  List<Map<String, dynamic>> _list(dynamic v) =>
      (v as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
}

/// 一部短剧的相关推荐单元（seriesRecommend）。
class Recommend {
  const Recommend({this.cellTitle = '', this.items = const []});

  final String cellTitle;
  final List<SeriesSummary> items;

  factory Recommend.fromJson(Map<String, dynamic> json) => Recommend(
        cellTitle: json['cell_title'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SeriesSummary.fromJson)
            .toList(),
      );
}
