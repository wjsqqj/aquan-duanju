/// 搜索分页的收尾判定。
///
/// 背景（`search_screen.dart` 的历史缺陷）：服务端在某些情况下会回
/// `has_more=true` 但 `next_offset` 没推进（`sdk/catalog.go` 只在
/// `NextOffset > offset` 时才写 cursor），此时 cursor 退回空串，客户端会
/// **重新拉第 1 页**；条目又被 ID 去重全部丢弃，但页面仍然 `setState` 重建，
/// 触底占位格再次触发加载 —— 于是同一个游标被无限请求，界面一条不增，
/// 还会白白消耗匿名配额。
///
/// 因此这里采取**保守策略**：任何一种"看起来翻不动了"的信号都判定到底。
/// 代价是服务端若返回整页重叠（极罕见）会少拿一页，收益是彻底消灭无限请求。
library;

/// 这一页之后是否还应该继续翻页。
///
/// 四种退化一律返回 false：
/// - [serverHasMore] 为 false（服务端说没有下一页）；
/// - [newItemCount] 为 0（整页都是重复项或空页，继续翻只会重复）；
/// - [nextCursor] 为空（服务端没给可用的下一页游标）；
/// - [nextCursor] 与 [requestCursor] 相同（游标没推进，再翻就是同一页）。
bool hasMoreAfterPage({
  required bool serverHasMore,
  required String requestCursor,
  required String nextCursor,
  required int newItemCount,
}) {
  if (!serverHasMore) return false;
  if (newItemCount <= 0) return false;
  if (nextCursor.isEmpty) return false;
  if (nextCursor == requestCursor) return false;
  return true;
}
