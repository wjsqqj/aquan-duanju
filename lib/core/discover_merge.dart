/// 发现页「缓存先展示、后台刷新」的合并规则。
///
/// 参考 `kaixinguo/data.go` 的 `feed.add()`：刷新拿到第一页时**新内容在前、
/// 旧缓存垫后**，网格只增不减——用户不会看到自己刚浏览过的一排卡片突然消失，
/// 新上架的内容又排在最前面。
///
/// 去重按 id；id 为空的条目（极少见）保留但不去重，避免把异常数据悄悄吃掉。
List<T> mergeDiscoverItems<T>(
  List<T> fresh,
  List<T> cached, {
  required String Function(T item) idOf,
}) {
  final seen = <String>{};
  final merged = <T>[];
  for (final item in <T>[...fresh, ...cached]) {
    final id = idOf(item);
    if (id.isEmpty) {
      merged.add(item);
      continue;
    }
    if (!seen.add(id)) continue;
    merged.add(item);
  }
  return merged;
}
