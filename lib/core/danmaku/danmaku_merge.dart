/// 弹幕「同句合并」：同一段文字在短时间内只保留一条。
///
/// 对齐参考实现 `kaixinguo/danmaku.go` 的 `danmakuRepeat = 20_000`：观众刷屏
/// 「+1」时，屏幕上不该同时飞过几十条一模一样的句子。比较的是**归一化文本**
/// （去首尾空白、压缩连续空白、忽略大小写），并且只和**已保留**的同类弹幕比
/// 时间差——这样 0s / 15s / 30s 三条里，15s 被合并、30s 仍会出现（30s 与
/// 已保留的 0s 相差超过窗口）。
library;

/// 默认合并窗口（毫秒）。
const int kDanmakuMergeWindowMs = 20000;

/// 过滤 [items] 中窗口内重复的同句弹幕。
///
/// [offsetOf] / [textOf] 让函数同时适用于红果 `models.DanmakuItem` 与 bili
/// `core/bili/api.dart` 的 `DanmakuItem`。[items] 需按时间升序（调用方已排序）。
/// [windowMs] <= 0 表示不合并（原样返回）。
List<T> mergeSameDanmaku<T>(
  List<T> items, {
  required int Function(T item) offsetOf,
  required String Function(T item) textOf,
  int windowMs = kDanmakuMergeWindowMs,
}) {
  if (windowMs <= 0 || items.length < 2) return items;

  final List<T> kept = <T>[];
  final Map<String, int> lastKeptAt = <String, int>{};
  for (final T item in items) {
    final String key = normalizeDanmakuText(textOf(item));
    if (key.isEmpty) continue;
    final int at = offsetOf(item);
    final int? last = lastKeptAt[key];
    if (last != null && (at - last).abs() < windowMs) continue;
    lastKeptAt[key] = at;
    kept.add(item);
  }
  return kept;
}

/// 弹幕文本归一化：去首尾空白、连续空白压成一个空格、转小写。
///
/// 只在比较时使用，展示仍是原文。
String normalizeDanmakuText(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// 合并后的一条弹幕 + 它代表了几条重复（用于展示「×N」）。
class CountedDanmaku<T> {
  const CountedDanmaku({required this.item, this.repeat = 1});

  final T item;

  /// 窗口内被并进来的条数（含本体，最小 1）。
  final int repeat;

  CountedDanmaku<T> withRepeat(int value) =>
      CountedDanmaku<T>(item: item, repeat: value);
}

/// [mergeSameDanmaku] 的计数版：窗口内重复句归并到最早一条并累加 [repeat]。
///
/// 与丢弃版语义完全一致（只和「已保留」的同类比时间差、空白/大小写归一、
/// 空白文本直接丢弃），区别只是把被合并的条数记下来而不是丢掉。
List<CountedDanmaku<T>> mergeSameDanmakuCounted<T>(
  List<T> items, {
  required int Function(T item) offsetOf,
  required String Function(T item) textOf,
  int windowMs = kDanmakuMergeWindowMs,
}) {
  if (items.isEmpty) return const [];
  final List<CountedDanmaku<T>> kept = <CountedDanmaku<T>>[];
  // 归一化文本 → 已保留条目在 kept 中的下标。
  final Map<String, int> lastIndex = <String, int>{};
  for (final T item in items) {
    final String key = normalizeDanmakuText(textOf(item));
    if (key.isEmpty) continue;
    final int at = offsetOf(item);
    final int? index = windowMs > 0 ? lastIndex[key] : null;
    if (index != null && (at - offsetOf(kept[index].item)).abs() < windowMs) {
      kept[index] = kept[index].withRepeat(kept[index].repeat + 1);
      continue;
    }
    lastIndex[key] = kept.length;
    kept.add(CountedDanmaku<T>(item: item));
  }
  return kept;
}
