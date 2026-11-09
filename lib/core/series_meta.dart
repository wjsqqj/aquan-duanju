import '../models/models.dart';

/// 批量取详情元信息的函数（真实实现传 `AquaApi.getSeriesBatch`）。
typedef SeriesMetaFetcher = Future<List<SeriesDetail>> Function(List<String> ids);

/// 详情接口补出来的封面元信息。
class SeriesMeta {
  const SeriesMeta({
    this.heat = 0,
    this.playCount = 0,
    this.tags = const [],
  });

  /// 原始热度分（hot_score），0 = 详情也没给。
  final int heat;

  /// 总播放量，0 = 详情也没给。
  final int playCount;

  /// 标签（详情 rows kind=3，与发现流传下来的 tags 同源）。
  final List<String> tags;
}

/// 列表卡片的「热度/标签」补全器。
///
/// 背景（2026-11-09 真实接口实测）：
/// - 发现流列表行带 `tags`，但不带 `hot_score`；
/// - 搜索、榜单、筛选的列表行连 `tags` 都没有；
/// - 热度和标签只在详情接口（`heat` / `rows kind=3`）里。
///
/// 列表页拿到一页数据后调用 [enrich]，用一次批量详情请求把缺的字段补齐，
/// 调用方按返回的条目原地替换即可刷新封面；不阻塞首屏、失败静默。
///
/// 会话级缓存：同一部剧只拉一次，正在拉的 id 不重复发；列表重进/翻回
/// 上一页直接命中缓存。只对纯数字 ID 发请求——非数字 ID（站外源）会让
/// SDK 拒绝整批；服务端不认识的数字 ID 会跳过，不会报错。
class SeriesMetaEnricher {
  SeriesMetaEnricher({this.cacheLimit = 500});

  /// 全局单例：缓存跨页面共享（搜索 → 详情 → 返回不重复请求）。
  static final SeriesMetaEnricher instance = SeriesMetaEnricher();

  /// 缓存条目上限；超出后按写入顺序淘汰最早的。
  final int cacheLimit;

  final Map<String, SeriesMeta> _cache = {};
  final Set<String> _inflight = {};

  /// 详情接口明确没返回的 ID（帖子/用户等非剧集行）：本会话不再重试。
  final Set<String> _misses = {};

  static final RegExp _numericId = RegExp(r'^\d{6,}$');

  /// 清空会话缓存（测试用；换匿名设备后也可丢弃旧账号下的元信息）。
  void clear() {
    _cache.clear();
    _inflight.clear();
    _misses.clear();
  }

  /// 补全 [items] 里缺热度或标签的条目，返回**有变化**的条目（保持原顺序）。
  ///
  /// [fetch] 传 `api.getSeriesBatch`。网络/解析失败时静默返回已缓存能补上
  /// 的部分——封面维持列表接口给的数据，下次列表刷新会再试。
  Future<List<SeriesSummary>> enrich(
    List<SeriesSummary> items,
    SeriesMetaFetcher fetch,
  ) async {
    final ids = <String>[];
    final wanted = <String>{};
    for (final item in items) {
      final id = item.id;
      if (id.isEmpty || !_numericId.hasMatch(id)) continue;
      if (wanted.contains(id)) continue;
      if (item.heat > 0 && item.tags.isNotEmpty) continue; // 已经齐了
      if (_cache.containsKey(id) ||
          _inflight.contains(id) ||
          _misses.contains(id)) {
        continue;
      }
      wanted.add(id);
      ids.add(id);
    }

    if (ids.isNotEmpty) {
      _inflight.addAll(ids);
      try {
        final details = await fetch(ids);
        final fetched = <String>{};
        for (final detail in details) {
          final series = detail.series;
          if (series == null || series.id.isEmpty) continue;
          fetched.add(series.id);
          final tags = <String>[
            for (final row in series.rows)
              if (row.kind == 3 && row.text.trim().isNotEmpty) row.text.trim(),
          ];
          _cache[series.id] = SeriesMeta(
            heat: series.heat,
            playCount: series.playCount,
            tags: tags,
          );
        }
        for (final id in ids) {
          if (!fetched.contains(id)) _misses.add(id);
        }
      } catch (_) {
        // 失败静默：封面维持列表接口数据，下次刷新再补。
      } finally {
        _inflight.removeAll(ids);
      }
    }

    final out = <SeriesSummary>[];
    final emitted = <String>{};
    for (final item in items) {
      final meta = _cache[item.id];
      if (meta == null || !emitted.add(item.id)) continue;
      final heat = item.heat > 0 ? item.heat : meta.heat;
      final playCount = item.playCount > 0 ? item.playCount : meta.playCount;
      final tags = item.tags.isNotEmpty ? item.tags : meta.tags;
      if (heat == item.heat &&
          playCount == item.playCount &&
          _sameTags(tags, item.tags)) {
        continue;
      }
      out.add(item.withMeta(heat: heat, playCount: playCount, tags: tags));
    }
    _evict();
    return out;
  }

  void _evict() {
    while (_cache.length > cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }

  static bool _sameTags(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
