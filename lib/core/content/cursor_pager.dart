/// 游标分页的通用去重容器。
///
/// 服务端分页常见两种坑：
/// 1. 相邻两页有重复条目（游标边界重复）；
/// 2. 已经到底了还返回 `hasMore: true`，列表无限请求同一批数据。
///
/// [CursorPager] 用「id 集合」消除第一种，用「连续空页 / 零新增」判第二种。
/// 纯逻辑，不依赖 Flutter，便于单测。
class CursorPager<T> {
  CursorPager({required this.idOf, this.emptyPageLimit = 2});

  /// 稳定 id（用于去重）。
  final String Function(T) idOf;

  /// 连续多少页「零新增」判为到底。
  final int emptyPageLimit;

  final List<T> _items = <T>[];
  final Set<String> _seen = <String>{};
  String _cursor = '';
  bool _hasMore = true;
  int _emptyStreak = 0;

  List<T> get items => List<T>.unmodifiable(_items);

  int get length => _items.length;

  bool get isEmpty => _items.isEmpty;

  String get cursor => _cursor;

  bool get hasMore => _hasMore;

  bool get exhausted => !_hasMore;

  /// 追加一页，返回真正新增的条数。
  ///
  /// [hasMore] 来自服务端；连续 [emptyPageLimit] 页零新增时强制置 false，
  /// 防止「服务端一直说还有下一页，但内容全是旧的」造成死循环。
  int addPage({
    required List<T> page,
    required String cursor,
    required bool hasMore,
  }) {
    var added = 0;
    for (final item in page) {
      final id = idOf(item);
      if (id.isEmpty) {
        // 没有 id 的条目无法去重，直接收（保持原行为）。
        _items.add(item);
        added++;
        continue;
      }
      if (_seen.add(id)) {
        _items.add(item);
        added++;
      }
    }
    _cursor = cursor;
    if (page.isEmpty || added == 0) {
      _emptyStreak++;
      if (page.isEmpty || _emptyStreak >= emptyPageLimit) {
        _hasMore = false;
      } else {
        _hasMore = hasMore;
      }
    } else {
      _emptyStreak = 0;
      _hasMore = hasMore;
    }
    return added;
  }

  /// 清空（下拉刷新 / 切频道）。
  void reset() {
    _items.clear();
    _seen.clear();
    _cursor = '';
    _hasMore = true;
    _emptyStreak = 0;
  }

  /// 是否包含某个 id（UI 判重、高亮用）。
  bool contains(String id) => _seen.contains(id);
}
