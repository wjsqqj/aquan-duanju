import 'source_adapter.dart';

/// 源注册表的纯逻辑助手：去重、排序、归一化（持久化在 stores.dart 的 store 类里）。
///
/// 展示排序语义（tvbox/xiugou 同构）：钉选 > 启用 > 健康分 > 延迟升序。
List<SourceConfig> sortSourcesForDisplay(
  Iterable<SourceConfig> sources, {
  required int Function(SourceConfig config) scoreOf,
  required int Function(SourceConfig config) latencyOf,
}) {
  final list = List.of(sources);
  list.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
    final byScore = scoreOf(b).compareTo(scoreOf(a));
    if (byScore != 0) return byScore;
    return latencyOf(a).compareTo(latencyOf(b));
  });
  return list;
}

/// 候选去重：按 kind + api 归一化（去尾斜杠）合并，保留首个名称。
List<SourceCandidate> dedupeCandidates(Iterable<SourceCandidate> candidates) {
  final seen = <String, SourceCandidate>{};
  for (final c in candidates) {
    if (!c.usable) continue;
    final key =
        '${c.kind.name}|${c.api.endsWith('/') ? c.api.substring(0, c.api.length - 1) : c.api}';
    seen.putIfAbsent(key, () => c);
  }
  return seen.values.toList();
}

/// CMS 搜索结果的归一化去重键：标题 + 年份。
String dedupeKeyForSeries(String normalizedTitle, String year) =>
    '$normalizedTitle@$year';
