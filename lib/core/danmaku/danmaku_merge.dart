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
