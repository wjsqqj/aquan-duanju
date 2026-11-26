import '../../models/models.dart';

/// 主搜索页的来源筛选。
///
/// 纯前端过滤：两个来源各自只有一次请求，切筛选不重新联网（红果的翻页游标
/// 与西饭的第一页结果都保持原样）。
enum SearchSourceFilter { all, hongguo, xifan }

extension SearchSourceFilterX on SearchSourceFilter {
  String get label => switch (this) {
        SearchSourceFilter.all => '全部来源',
        SearchSourceFilter.hongguo => '红果',
        SearchSourceFilter.xifan => '西饭',
      };
}

/// 当前筛选是否展示红果结果（决定「加载更多」页脚是否可用）。
bool showsHongguo(SearchSourceFilter filter) =>
    filter != SearchSourceFilter.xifan;

/// 当前筛选是否展示西饭结果。
bool showsXifan(SearchSourceFilter filter) =>
    filter != SearchSourceFilter.hongguo;

/// 组合两个来源的结果：红果在前（保持既有排序与季归并），西饭在后。
///
/// 两边的 `id` 天然不冲突（红果是纯数字，西饭是 `xifan:<source>:<duanjuId>`），
/// 所以不做跨源去重——同一部剧在两个平台都有时，用户应当看到两个来源的条目，
/// 各自点开走各自的播放链路（这是「标明来源」的意义）。
List<SeriesSummary> composeSearchResults({
  required List<SeriesSummary> hongguo,
  required List<SeriesSummary> xifan,
  required SearchSourceFilter filter,
}) {
  final List<SeriesSummary> out = <SeriesSummary>[];
  if (showsHongguo(filter)) out.addAll(hongguo);
  if (showsXifan(filter)) out.addAll(xifan);
  return out;
}

/// 西饭条目在列表里应展示的来源角标（红果条目不加角标，避免视觉噪音）。
String? searchSourceBadge(SeriesSummary item) =>
    item.kind == 'xifan' ? '西饭' : null;
