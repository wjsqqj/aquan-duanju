/// 搜索结果的「同剧多季」归并排序。
///
/// 上游搜索接口是**剧级**的（`SeriesSummary` 没有 season 字段），同一部剧的各季
/// 只能靠标题识别：`XXX第二季` / `XXX 第 2 部` / `XXX（第三季）`。
/// 需求：同一部剧的各季按顺序排好 —— 把同前缀的季卡聚到**首季所在位置**，
/// 季号升序；非季条目保持原相对顺序（稳定排序）。
///
/// 参考实现：`kaixinguo-android/.../model/Seasons.kt` `orderSeasons()`。
library;

import '../../models/models.dart';
import '../season_number.dart';

/// 季标记：`第 2 季` / `第二部`（允许中间有空格）。
final RegExp _seasonMark = RegExp(
  r'第\s*([0-9]{1,3}|[零〇一二两三四五六七八九十百]{1,4})\s*[季部]',
);

/// 组名尾部需要剥掉的装饰与标点（`XXX（第二季）` 的 `（`）。
final RegExp _groupTail = RegExp(r'[\s·\-—_、,，:：\(（\[【「『]+$');

/// 从标题解析「组名 + 季号」；没有季标记返回 null。
///
/// 取**最后一处**季标记：`《某某》第二季 第三部` 这种标题以最后一段为准，
/// 避免前缀本身含季号时把组名切错。
({String group, int season})? parseSeasonKey(String title) {
  final String trimmed = title.trim();
  if (trimmed.isEmpty) return null;
  final Iterable<RegExpMatch> matches = _seasonMark.allMatches(trimmed);
  if (matches.isEmpty) return null;
  final RegExpMatch mark = matches.last;
  final String group =
      trimmed.substring(0, mark.start).replaceAll(_groupTail, '').trim();
  // 组名为空（标题本身就是「第二季」）时不做归并，否则会把无关剧集聚到一起。
  if (group.isEmpty) return null;
  final int? season = chineseNumber(mark.group(1) ?? '');
  if (season == null || season <= 0) return null;
  return (group: group, season: season);
}

/// 同部剧里当前季之后**可播**的下一季（跳过未上线 / 空季）。
///
/// 参考 `kaixinguo/data.go` 的 `seriesPage.nextSeason()`：只在合集里向后找，
/// 不回绕；`episodeCount <= 0` 的季还没上线，自动连播不能跳过去。
Season? nextPlayableSeason(
  List<Season> seasons,
  String currentSeriesId,
) {
  if (seasons.isEmpty || currentSeriesId.isEmpty) return null;
  var current = -1;
  for (var i = 0; i < seasons.length; i++) {
    if (seasons[i].seriesId == currentSeriesId) {
      current = i;
      break;
    }
  }
  if (current < 0) return null;
  for (var i = current + 1; i < seasons.length; i++) {
    final season = seasons[i];
    if (season.seriesId.isEmpty || season.seriesId == currentSeriesId) continue;
    if (season.episodeCount <= 0) continue;
    return season;
  }
  return null;
}

/// 是否还有可播的下一季。
bool hasNextPlayableSeason(List<Season> seasons, String currentSeriesId) =>
    nextPlayableSeason(seasons, currentSeriesId) != null;

/// 归并排序后的新列表（原列表不变）。
///
/// 排序键：`(该组首条下标 ?? 自身下标, 季号, 原下标)`。第三键保证稳定，
/// 非季条目的相对顺序因此不会被打乱。
List<T> orderSeasonResults<T>(
  List<T> items, {
  required String Function(T item) titleOf,
}) {
  if (items.length < 2) return items;

  final List<({String group, int season})?> keys =
      <({String group, int season})?>[
    for (final T item in items) parseSeasonKey(titleOf(item)),
  ];
  if (keys.every((key) => key == null)) return items;

  final Map<String, int> firstIndex = <String, int>{};
  for (int i = 0; i < keys.length; i++) {
    final key = keys[i];
    if (key != null) firstIndex.putIfAbsent(key.group, () => i);
  }

  final List<int> order = List<int>.generate(items.length, (int i) => i);
  order.sort((int a, int b) {
    final keyA = keys[a];
    final keyB = keys[b];
    final int rankA = keyA == null ? a : firstIndex[keyA.group]!;
    final int rankB = keyB == null ? b : firstIndex[keyB.group]!;
    if (rankA != rankB) return rankA.compareTo(rankB);
    final int seasonA = keyA?.season ?? 0;
    final int seasonB = keyB?.season ?? 0;
    if (seasonA != seasonB) return seasonA.compareTo(seasonB);
    return a.compareTo(b);
  });

  // 顺序未变时直接返回原列表，避免上层无意义的 rebuild。
  bool changed = false;
  for (int i = 0; i < order.length; i++) {
    if (order[i] != i) {
      changed = true;
      break;
    }
  }
  if (!changed) return items;
  return <T>[for (final int i in order) items[i]];
}
