import 'normal_title.dart';
import 'source_adapter.dart';

/// 跨线路定位「同一集」：换线路后不应该把用户丢回第 1 集。
///
/// 优先级：
/// 1. 集名归一化（[normalizeEpisodeName]）后**唯一**命中——不同线路的集名
///    通常一致（「第3集」「03」「3」归一化后同名）；
/// 2. [UnifiedEpisode.index]（1 基分集序号）**唯一**命中；
/// 3. 原下标 clamp（线路集数不同时的兜底）。
///
/// 「唯一命中」是硬规则：归一化后出现多条同名（预告/花絮/重复分集）时
/// 宁可退回序号，也不猜——猜错会把用户带到另一集的内容。
int matchEpisodeIndex({
  required List<UnifiedEpisode> from,
  required int fromIndex,
  required List<UnifiedEpisode> to,
}) {
  if (to.isEmpty) return 0;
  if (from.isEmpty) return 0;

  final safeFrom = fromIndex.clamp(0, from.length - 1);
  final current = from[safeFrom];

  final name = normalizeEpisodeName(current.title);
  if (name.isNotEmpty) {
    final hits = <int>[];
    for (var i = 0; i < to.length; i++) {
      if (normalizeEpisodeName(to[i].title) == name) hits.add(i);
    }
    if (hits.length == 1) return hits.single;
  }

  final byNumber = <int>[];
  for (var i = 0; i < to.length; i++) {
    if (to[i].index == current.index) byNumber.add(i);
  }
  if (byNumber.length == 1) return byNumber.single;

  return safeFrom.clamp(0, to.length - 1);
}
