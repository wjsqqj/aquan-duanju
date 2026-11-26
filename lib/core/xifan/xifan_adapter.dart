import '../sources/source_adapter.dart';
import 'xifan_api.dart';

/// 西饭 → [SourceAdapter] 适配器。
///
/// 目的不是「再做一个 CMS 源」，而是让西饭剧集能直接复用现成的
/// [SourcePlayerScreen]（mpv 直链、手势、投屏、续播、历史全免费），
/// 同时给聚合搜索留一条可选接入路径。
class XifanAdapter implements SourceAdapter {
  XifanAdapter(this._api);

  final XifanApi _api;

  static const String sourceKey = 'xifan';

  @override
  String get id => sourceKey;

  @override
  String get name => '西饭';

  @override
  SourceCaps get caps =>
      const SourceCaps(searchable: true, filterable: false, multiLine: false);

  /// 解析 `xifan:<source>:<duanjuId>` 或 `<source>:<duanjuId>`。
  static ({String source, String duanjuId})? parseItemId(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;
    final List<String> parts = text.split(':');
    if (parts.length == 3 && parts[0] == sourceKey) {
      return (source: parts[1], duanjuId: parts[2]);
    }
    if (parts.length == 2) {
      return (source: parts[0], duanjuId: parts[1]);
    }
    return null;
  }

  /// 搜索页用：把搜索结果映射成统一内模。
  static UnifiedSeries toUnified(XifanSearchItem item) => UnifiedSeries(
        sourceKey: sourceKey,
        sourceItemId: '${item.source}:${item.duanjuId}',
        title: item.title,
        normalizedTitle: item.title,
        coverUrl: item.coverUrl,
        remarks: item.total > 0 ? '${item.total} 集' : '',
        description: item.description,
      );

  @override
  Future<List<SourceCategory>> categories() async => const [];

  @override
  Future<SourcePage<UnifiedSeries>> list({
    String? categoryId,
    required int page,
  }) async =>
      SourcePage<UnifiedSeries>(items: const [], page: page);

  @override
  Stream<SourceSearchEvent> search(
    String query, {
    int page = 1,
    CancelToken? cancel,
  }) async* {
    try {
      final XifanSearchPage result = await _api.search(query, page: page);
      if (cancel?.isCancelled ?? false) {
        yield const SourceSearchDone();
        return;
      }
      yield SourceHits(
        items: [for (final item in result.items) toUnified(item)],
        page: result.page,
        hasMore: result.hasMore,
      );
    } on XifanException catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.network, e.message);
    } catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.searchInvalid, '$e');
    }
    yield const SourceSearchDone();
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    final parsed = parseItemId(sourceItemId);
    if (parsed == null) {
      throw SourceException(
          SourceExceptionCode.searchInvalid, '西饭剧集编号无效：$sourceItemId');
    }
    try {
      final XifanDrama drama =
          await _api.detail(parsed.source, parsed.duanjuId);
      return toUnifiedDrama(drama);
    } on XifanException catch (e) {
      throw SourceException(SourceExceptionCode.network, e.message);
    }
  }

  /// 详情页已经拿到 [XifanDrama] 时直接构建，避免为播放再请求一次详情。
  static UnifiedSeries toUnifiedDrama(XifanDrama drama) => UnifiedSeries(
        sourceKey: sourceKey,
        sourceItemId: '${drama.source}:${drama.duanjuId}',
        title: drama.title,
        normalizedTitle: drama.title,
        coverUrl: drama.coverUrl,
        remarks: '${drama.episodes.length} 集',
        description: drama.description,
        lines: <PlayLine>[
          PlayLine(
            name: '西饭',
            episodes: <UnifiedEpisode>[
              for (final e in drama.episodes)
                if (e.playUrl.isNotEmpty)
                  UnifiedEpisode(
                    title: e.title.isEmpty ? '第${e.index}集' : e.title,
                    url: e.playUrl,
                    index: e.index,
                  ),
            ],
          ),
        ],
        headers: const <String, String>{'User-Agent': 'Mozilla/5.0'},
      );

  @override
  Future<String> probePlayable({String? itemId}) async {
    if (itemId == null || itemId.isEmpty) return '';
    try {
      final UnifiedSeries series = await detail(itemId);
      final PlayLine? line = series.defaultLine;
      if (line == null || line.episodes.isEmpty) return '';
      return await _api.resolvePlayUrl(line.episodes.first.url);
    } catch (_) {
      return '';
    }
  }
}
