import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/models.dart';

/// 红果官网（hongguoduanju.com）无签名搜索接口。
///
/// 存在的意义：App 签名搜索接口（`AquaApi.search` → Go SDK，
/// `api5-normal-sinfonlineb.fqnovel.com`）依赖设备指纹与 x-gorgon 一类签名，
/// 一旦上游风控策略变化就会整条链路失败。官网 H5 接口无签名、结构简单，
/// 是同一内容库的**备用通道**：结果里的 `series_id` 与 App 详情接口同体系，
/// 点开仍走现有红果详情/播放链路，体验不分叉。
///
/// 实测（2026-11-26）：`GET /api/search/result?aid=8662&query=重生&page=1`
/// 返回 200 + `searchList[].video_data`，218 条 / 22 页。纯静态 UA + Referer
/// 即可，无需 Cookie。
class HongguoWebSearch {
  HongguoWebSearch({
    http.Client? client,
    // 备用通道必须显著短于调用方的页面预算（搜索页 20s，且退化重试最多
    // 再走 2 次）：10s 会撑爆预算，把「已经拿到的结果」整页丢掉。
    this.timeout = const Duration(seconds: 4),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  static const String baseUrl =
      'https://hongguoduanju.com/api/search/result';
  static const String origin = 'https://hongguoduanju.com';

  /// 站点固定 aid（官网搜索页用值）。
  static const String aid = '8662';

  static const Map<String, String> _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': '$origin/',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 游标前缀：让搜索页的「加载更多」能识别这一页来自备用通道。
  static const String cursorPrefix = 'web:';

  static int? pageOfCursor(String cursor) {
    if (!cursor.startsWith(cursorPrefix)) return null;
    return int.tryParse(cursor.substring(cursorPrefix.length));
  }

  /// 搜索一页；失败抛 [HongguoWebSearchException]（调用方决定是否降级）。
  Future<AquaPage<SeriesSummary>> search(String query, {int page = 1}) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return const AquaPage<SeriesSummary>(items: []);
    }
    final Uri uri = Uri.parse(baseUrl).replace(queryParameters: {
      'aid': aid,
      'query': q,
      'page': '${page < 1 ? 1 : page}',
    });

    late final http.Response res;
    try {
      res = await _client.get(uri, headers: _headers).timeout(timeout);
    } on TimeoutException {
      throw const HongguoWebSearchException('红果备用接口超时，请稍后重试');
    } catch (e) {
      throw HongguoWebSearchException('红果备用接口不可用：$e');
    }
    if (res.statusCode != 200) {
      throw HongguoWebSearchException('红果备用接口返回 ${res.statusCode}');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (e) {
      throw HongguoWebSearchException('红果备用接口返回结构异常：$e');
    }
    if (decoded is! Map) {
      throw const HongguoWebSearchException('红果备用接口返回结构异常');
    }
    final Map<String, dynamic> map = decoded.cast<String, dynamic>();
    final List<dynamic> raw = map['searchList'] is List
        ? map['searchList'] as List<dynamic>
        : const <dynamic>[];

    final List<SeriesSummary> items = <SeriesSummary>[];
    final Set<String> seen = <String>{};
    for (final entry in raw) {
      final SeriesSummary? item = _parseEntry(entry);
      if (item == null) continue;
      if (!seen.add(item.id)) continue;
      items.add(item);
    }

    final int parsedPage = _asInt(map['pageNum']);
    final int pageNum = parsedPage > 0 ? parsedPage : page;
    final int totalPages = _asInt(map['totalPages']);
    final bool hasMore = map['hasMore'] is bool
        ? map['hasMore'] as bool
        : totalPages > pageNum;
    return AquaPage<SeriesSummary>(
      items: items,
      cursor: hasMore ? '$cursorPrefix${pageNum + 1}' : '',
      hasMore: hasMore && items.isNotEmpty,
    );
  }

  /// 释放内部创建的 client（注入 client 时不动，调用方自己管理）。
  void close() {
    if (_ownsClient) _client.close();
  }

  static final RegExp _seriesId = RegExp(r'^\d{6,}$');

  SeriesSummary? _parseEntry(Object? entry) {
    if (entry is! Map) return null;
    final Object? data = entry['video_data'];
    if (data is! Map) return null;
    final Map<String, dynamic> v = data.cast<String, dynamic>();
    final String id = _asString(v['series_id']);
    if (!_seriesId.hasMatch(id)) return null;
    final String title = _asString(v['series_title']).trim();
    if (title.isEmpty) return null;

    final List<String> tags = <String>[];
    final Object? categories = v['category_list'];
    if (categories is List) {
      for (final c in categories) {
        if (c is Map) {
          final String name = _asString(c['name']).trim();
          if (name.isNotEmpty) tags.add(name);
        }
      }
    }

    int heat = 0;
    final Object? hot = v['hot_score_data'];
    if (hot is Map) heat = _asInt(hot['score']);

    return SeriesSummary(
      id: id,
      title: title,
      description: _asString(v['series_intro']).trim(),
      coverUrl: _asString(v['series_cover']).trim(),
      episodeCount: _asInt(v['episode_cnt']),
      heat: heat,
      tags: tags.take(4).toList(growable: false),
      score: v['rating'] is num ? '${v['rating']}' : '',
    );
  }

  static String _asString(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) return '$value';
    return '';
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

/// 备用通道失败：文案可直接给用户看（detail 已在 message 里，仅供日志）。
class HongguoWebSearchException implements Exception {
  const HongguoWebSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}
