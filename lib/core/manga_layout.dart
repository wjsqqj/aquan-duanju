/// 漫画拼版：横屏双页相关的纯计算，便于单测。
library;

/// 是否启用双页拼版：开关打开且屏幕是横向的。
bool useSpread({
  required double width,
  required double height,
  required bool enabled,
}) =>
    enabled && width > height;

/// 把 [total] 页按「两页一屏」分组；最后一页落单时单独一屏。
///
/// 顺序保持原样，返回的是每一屏的页下标。
List<List<int>> spreadGroups(int total) {
  if (total <= 0) return const [];
  final groups = <List<int>>[];
  for (var i = 0; i < total; i += 2) {
    if (i + 1 < total) {
      groups.add([i, i + 1]);
    } else {
      groups.add([i]);
    }
  }
  return groups;
}
