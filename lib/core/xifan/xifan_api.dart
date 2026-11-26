import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 西饭短剧（xifan-api-cn.youlishipin.com）接口客户端。
///
/// 为什么单独建一套而不是塞进 CMS 适配器：西饭不是 TVBox/CMS 协议，字段名
/// （`duanjuVo` / `episodeList` / `playUrl`）与 CMS 完全不同，硬套会污染
/// `sources` 契约。这里只做「自有接口 → 统一内模」的薄映射。
///
/// 实测（2026-11-26）：
/// - 搜索 `GET /xifan/search/getSearchList?keyword=&pageIndex=` →
///   `result.elements[].contents[].duanjuVo{source,duanjuId,title,...}`；
/// - 详情 `GET /xifan/drama/getDuanjuInfo?source=&duanjuId=` →
///   `result.episodeList[]{episodeId,index,title,playUrl,unlock}`；
/// - `playUrl` 是 302 跳转到签名 mp4（约 1 小时有效），所以**不缓存**解析结果。
class XifanApi {
  XifanApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.resolveTimeout = const Duration(seconds: 3),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// 解析 302 最终地址的超时：解析失败就用原地址交给播放器跟随跳转。
  final Duration resolveTimeout;

  static const String base = 'https://xifan-api-cn.youlishipin.com';

  /// 早期客户端版本号（上游当前仍接受；拒绝时按「来源暂不可用」降级）。
  static const String clientVersion = '2001001';
  static const String androidVersionCode = '28';

  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'Mozilla/5.0',
    'Accept': 'application/json',
  };

  static final RegExp _token = RegExp(r'^[a-zA-Z0-9_-]{1,200}$');

  /// 搜索一页。失败抛 [XifanException]。
  Future<XifanSearchPage> search(String keyword, {int page = 1}) async {
    final String kw = keyword.trim();
    if (kw.isEmpty) return const XifanSearchPage(items: [], page: 1);
    final Map<String, dynamic> result = await _get('/xifan/search/getSearchList', {
      'keyword': kw,
      'pageIndex': '${page < 1 ? 1 : page}',
    });
    final List<XifanSearchItem> items = <XifanSearchItem>[];
    final Set<String> seen = <String>{};
    for (final element in _asList(result['elements'])) {
      if (element is! Map) continue;
      for (final content in _asList(element['contents'])) {
        if (content is! Map) continue;
        final Object? vo = content['duanjuVo'];
        if (vo is! Map) continue;
        final XifanSearchItem? item = XifanSearchItem.fromJson(vo);
        if (item == null) continue;
        if (!seen.add(item.seriesId)) continue;
        items.add(item);
      }
    }
    return XifanSearchPage(
      items: items,
      page: page,
      hasMore: result['hasMore'] == true && items.isNotEmpty,
    );
  }

  /// 详情（含全部分集）。`source`/`duanjuId` 来自搜索结果。
  Future<XifanDrama> detail(String source, String duanjuId) async {
    if (!_token.hasMatch(source) || !_token.hasMatch(duanjuId)) {
      throw const XifanException('西饭剧集编号无效');
    }
    final Map<String, dynamic> result = await _get('/xifan/drama/getDuanjuInfo', {
      'source': source,
      'duanjuId': duanjuId,
    });
    final String gotDuanju = '${result['duanjuId'] ?? ''}';
    final String gotSource = '${result['source'] ?? ''}';
    if (gotDuanju.isNotEmpty && gotDuanju != duanjuId) {
      throw const XifanException('西饭返回的剧集与请求不一致');
    }
    if (gotSource.isNotEmpty && gotSource != source) {
      throw const XifanException('西饭返回的剧集与请求不一致');
    }
    final XifanDrama drama = XifanDrama.fromJson(result, source: source, duanjuId: duanjuId);
    if (drama.episodes.isEmpty) {
      throw const XifanException('西饭没有返回可用分集');
    }
    return drama;
  }

  /// 把 `playUrl` 解析成可直接喂给 mpv 的最终地址。
  ///
  /// 该地址是 AWS 签名链接（约 1h 有效），**不要缓存**；解析失败时返回原
  /// `playUrl`（mpv 自己会跟随 302）。
  ///
  /// 必须显式 `followRedirects = false`：http 包默认跟随 302，那样拿到的是
  /// CDN 的 200 响应，`location` 恒为空 —— 这段解析会永远走回退分支（静默空转）。
  Future<String> resolvePlayUrl(String playUrl) async {
    final String url = playUrl.trim();
    if (url.isEmpty) return '';
    try {
      final http.Request request = http.Request('HEAD', Uri.parse(url))
        ..followRedirects = false
        ..headers.addAll(_headers);
      final http.StreamedResponse res =
          await _client.send(request).timeout(resolveTimeout);
      final String? location = res.headers['location'];
      await res.stream.drain<void>();
      if (location != null && location.contains('.mp4')) {
        return location;
      }
    } catch (_) {
      // 静默回退：HEAD 失败（405 / 超时 / 代理）很常见，不影响播放。
    }
    return url;
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final Uri uri = Uri.parse('$base$path').replace(queryParameters: {
      ...query,
      'version': clientVersion,
      'androidVersionCode': androidVersionCode,
    });
    late final http.Response res;
    try {
      res = await _client.get(uri, headers: _headers).timeout(timeout);
    } on TimeoutException {
      throw const XifanException('西饭加载超时，请重试');
    } catch (e) {
      throw XifanException('西饭来源暂不可用，请稍后重试', '$e');
    }
    if (res.statusCode != 200) {
      throw XifanException('西饭来源暂不可用，请稍后重试', 'HTTP ${res.statusCode}');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (e) {
      throw XifanException('西饭返回结构异常', '$e');
    }
    if (decoded is! Map) {
      throw const XifanException('西饭返回结构异常');
    }
    final Map<String, dynamic> map = decoded.cast<String, dynamic>();
    if (map['ret'] != 0) {
      throw XifanException('西饭返回结构异常（ret=${map['ret']}）');
    }
    final Object? result = map['result'];
    if (result is! Map) {
      throw const XifanException('西饭返回结构异常（缺少 result）');
    }
    return result.cast<String, dynamic>();
  }

  static List<dynamic> _asList(Object? value) =>
      value is List ? value : const <dynamic>[];
}

/// 一页搜索结果。
class XifanSearchPage {
  const XifanSearchPage({
    required this.items,
    required this.page,
    this.hasMore = false,
  });

  final List<XifanSearchItem> items;
  final int page;
  final bool hasMore;
}

/// 搜索结果条目。
class XifanSearchItem {
  const XifanSearchItem({
    required this.source,
    required this.duanjuId,
    required this.title,
    this.coverUrl = '',
    this.description = '',
    this.total = 0,
    this.categories = const [],
  });

  final String source;
  final String duanjuId;
  final String title;
  final String coverUrl;
  final String description;
  final int total;
  final List<String> categories;

  /// 全局唯一 id（搜索页 `SeriesSummary.id` 用它，点击时再解析）。
  String get seriesId => 'xifan:$source:$duanjuId';

  static XifanSearchItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String source = '${raw['source'] ?? ''}'.trim();
    final String duanjuId = '${raw['duanjuId'] ?? ''}'.trim();
    final String title = _plain('${raw['title'] ?? ''}');
    if (source.isEmpty || duanjuId.isEmpty || title.isEmpty) return null;
    if (!XifanApi._token.hasMatch(source) ||
        !XifanApi._token.hasMatch(duanjuId)) {
      return null;
    }
    final List<String> categories = <String>[];
    final Object? rawCategories = raw['categories'];
    if (rawCategories is List) {
      for (final c in rawCategories) {
        final String name = _plain('$c');
        if (name.isNotEmpty) categories.add(name);
      }
    }
    return XifanSearchItem(
      source: source,
      duanjuId: duanjuId,
      title: title,
      coverUrl: _https('${raw['coverImageUrl'] ?? ''}'),
      description: _plain('${raw['desc'] ?? ''}'),
      total: _asInt(raw['total']),
      categories: categories.take(4).toList(growable: false),
    );
  }

  /// 从 `xifan:<source>:<duanjuId>` 还原（搜索页 id → 详情页参数）。
  static XifanSearchItem? fromSeriesId(String id) {
    final List<String> parts = id.split(':');
    if (parts.length != 3 || parts[0] != 'xifan') return null;
    if (!XifanApi._token.hasMatch(parts[1]) ||
        !XifanApi._token.hasMatch(parts[2])) {
      return null;
    }
    return XifanSearchItem(source: parts[1], duanjuId: parts[2], title: '');
  }
}

/// 详情 + 分集。
class XifanDrama {
  const XifanDrama({
    required this.source,
    required this.duanjuId,
    required this.title,
    this.coverUrl = '',
    this.description = '',
    this.total = 0,
    this.categories = const [],
    this.episodes = const [],
  });

  final String source;
  final String duanjuId;
  final String title;
  final String coverUrl;
  final String description;
  final int total;
  final List<String> categories;
  final List<XifanEpisode> episodes;

  String get seriesId => 'xifan:$source:$duanjuId';

  static XifanDrama fromJson(
    Map<String, dynamic> raw, {
    required String source,
    required String duanjuId,
  }) {
    final List<String> categories = <String>[];
    final Object? rawCategories = raw['categories'];
    if (rawCategories is List) {
      for (final c in rawCategories) {
        final String name = _plain('$c');
        if (name.isNotEmpty) categories.add(name);
      }
    }
    final List<XifanEpisode> episodes = <XifanEpisode>[];
    final Object? rawEpisodes = raw['episodeList'];
    if (rawEpisodes is List) {
      var fallback = 0;
      for (final e in rawEpisodes) {
        if (e is! Map) continue;
        fallback++;
        final XifanEpisode? episode = XifanEpisode.fromJson(e, fallback: fallback);
        if (episode != null) episodes.add(episode);
      }
      episodes.sort((a, b) => a.index.compareTo(b.index));
    }
    return XifanDrama(
      source: source,
      duanjuId: duanjuId,
      title: _plain('${raw['title'] ?? ''}'),
      coverUrl: _https('${raw['coverImageUrl'] ?? ''}'),
      description: _plain('${raw['desc'] ?? ''}'),
      total: _asInt(raw['total']),
      categories: categories.take(6).toList(growable: false),
      episodes: episodes,
    );
  }
}

/// 一集。
class XifanEpisode {
  const XifanEpisode({
    required this.episodeId,
    required this.index,
    required this.title,
    required this.playUrl,
    required this.unlock,
  });

  final String episodeId;
  final int index;
  final String title;

  /// 302 入口地址（点击播放时现解析）。
  final String playUrl;

  /// 上游 `unlock`：false = 该集在西饭需解锁，不给播。
  final bool unlock;

  static XifanEpisode? fromJson(Object? raw, {required int fallback}) {
    if (raw is! Map) return null;
    final String episodeId = '${raw['episodeId'] ?? ''}'.trim();
    if (!XifanApi._token.hasMatch(episodeId)) return null;
    final int index = _asInt(raw['index']);
    return XifanEpisode(
      episodeId: episodeId,
      index: index > 0 ? index : fallback,
      title: _plain('${raw['title'] ?? ''}'),
      playUrl: '${raw['playUrl'] ?? ''}'.trim(),
      unlock: raw['unlock'] == true,
    );
  }
}

/// 西饭接口失败：`message` 是可以直接展示给用户的一句话。
///
/// [detail] 只放原始异常文本，**只进 ErrorLog**（UI 契约：页面只显示
/// friendlyText，不把 `FormatException: Unexpected character…` 糊到脸上）。
class XifanException implements Exception {
  const XifanException(this.message, [this.detail = '']);

  final String message;
  final String detail;

  @override
  String toString() => detail.isEmpty ? message : '$message｜$detail';
}

String _plain(String value) =>
    value.replaceAll(RegExp(r'<[^>]*>'), '').trim();

String _https(String value) {
  final String v = value.trim();
  if (v.isEmpty) return '';
  return v.startsWith('https://') ? v : '';
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
