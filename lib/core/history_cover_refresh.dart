import '../models/models.dart';
import '../store/stores.dart';
import 'aqua_api.dart';

/// 一次批量详情最多查多少部剧（沿用「我的」页原有的分批口径）。
const int _batchSize = 10;

/// 封面 URL 带签名（`x-expires` 约 60 天），历史里存的是播放时的快照。
///
/// 签名 60 天才过期，没必要每次进页面都重拉一遍详情：24 小时内只成功刷新
/// 一次即可。主壳是 `IndexedStack` + `AutomaticKeepAliveClientMixin`，正常
/// 切 tab 不会重建 State；节流防的是 State 被重建（热重启、未来新入口）。
///
/// 只在**拿到至少一批成功结果**时更新：全部失败（离线、限流）不留时间戳，
/// 下次进页面还能立刻重试。进程级状态，不落盘——重启后重新刷一次是对的。
DateTime? _lastSuccessAt;

/// 批量取详情的函数（真实实现传 `AquaApi.getSeriesBatch`）。
typedef SeriesDetailsFetcher = Future<List<SeriesDetail>> Function(
    List<String> ids);

/// 红果剧集 ID 是纯数字；站外源历史 key 形如 `sourceKey:itemId`，
/// 发给 `getSeriesBatch` 会让 SDK 拒绝**整批**（实测结论见 series_meta.dart）。
final RegExp _numericId = RegExp(r'^\d{6,}$');

/// 批量取详情：过滤空 id / 非数字 id、去重，每批 [_batchSize] 个。
///
/// 单批失败静默跳过并继续后面的批次——封面刷新是尽力而为，一批网络抖动
/// 不该连累其余批次。
Future<List<SeriesDetail>> fetchSeriesDetailsBatched(
  SeriesDetailsFetcher fetch,
  Iterable<String> seriesIds,
) async {
  final ids = <String>[];
  final seen = <String>{};
  for (final raw in seriesIds) {
    final id = raw.trim();
    if (id.isEmpty || !_numericId.hasMatch(id) || !seen.add(id)) continue;
    ids.add(id);
  }
  if (ids.isEmpty) return const [];

  final details = <SeriesDetail>[];
  for (var i = 0; i < ids.length; i += _batchSize) {
    final batch = ids.sublist(i, (i + _batchSize).clamp(0, ids.length));
    try {
      details.addAll(await fetch(batch));
    } catch (_) {
      // 单批失败：跳过，继续下一批。
    }
  }
  return details;
}

/// 用最新的详情封面刷新历史记录，返回更新的条数。
///
/// [force] 为真时跳过 24 小时节流（例如用户点「刷新」）。任何异常都不外抛：
/// 封面旧了最多是裂图，不能让首页因此报错。
Future<int> refreshHistoryCovers(
  AquaApi api,
  HistoryStore history,
  Iterable<String> seriesIds, {
  bool force = false,
}) async {
  final last = _lastSuccessAt;
  if (!force &&
      last != null &&
      DateTime.now().difference(last) < const Duration(hours: 24)) {
    return 0;
  }
  try {
    final details = await fetchSeriesDetailsBatched(api.getSeriesBatch, seriesIds);
    final covers = <String, String>{
      for (final d in details)
        if (d.series != null && d.series!.coverUrl.isNotEmpty)
          d.series!.id: d.series!.coverUrl,
    };
    // 一批都没成功（或详情里没封面）：不更新节流时间，下次还能重试。
    if (covers.isEmpty) return 0;
    final changed = await history.refreshCovers(covers);
    _lastSuccessAt = DateTime.now();
    return changed;
  } catch (_) {
    return 0;
  }
}
