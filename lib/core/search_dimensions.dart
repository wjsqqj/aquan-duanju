/// 搜索的两个维度。
///
/// 上游把「作品」与「讨论」分成两种 tab：作品走综合（tab 空）并支持 filters；
/// 讨论走 `tab_type=31`，**不能带 filters**（SDK 直接拒绝：filters 只在综合 tab
/// 生效）。帖子只有 `post_id + title`，没有封面，所以讨论维度用行式列表而不是
/// 网格。
library;

/// 搜索维度。
enum SearchDimension {
  /// 作品：短剧、漫剧、小说等，可叠加内容筛选。
  content(label: '内容', tab: '', allowsFilters: true),

  /// 讨论：社区帖子。
  discussion(label: '讨论', tab: '讨论', allowsFilters: false);

  const SearchDimension({
    required this.label,
    required this.tab,
    required this.allowsFilters,
  });

  /// 维度条上的文案。
  final String label;

  /// 传给 core 的 tab；空即综合。
  final String tab;

  /// 该维度是否接受内容筛选。
  final bool allowsFilters;

  /// 该维度实际要传的筛选：讨论维度一律丢弃筛选。
  List<String> filtersFor(List<String> filters) =>
      allowsFilters ? filters : const [];
}
