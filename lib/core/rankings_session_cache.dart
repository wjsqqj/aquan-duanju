import '../models/models.dart';

/// 榜单的一页（首拉 / 切榜 / 下拉刷新成功后写入）。
class RankBoardPage {
  const RankBoardPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<RankItem> items;
  final String cursor;
  final bool hasMore;
}

/// 排行榜会话级缓存（纯内存，进程生命周期）。
///
/// 「先展示后刷新」：重进榜单页先用它即时渲染（无等待感），后台再静默
/// 刷新覆盖；榜单数据实时性要求低，值得拿陈旧度换秒开。只存**拉取成功**
/// 的结果（失败不写，避免坏数据在会话里反复回放）；不持久化，重启即空。
class RankingsSessionCache {
  RankingsSessionCache._();

  /// 全局单例：与页面 State 解耦（页面拆树重建后重进仍命中）。
  static final RankingsSessionCache instance = RankingsSessionCache._();

  /// 单页缓存上限（首拉/切榜页正常 20~30 行；防御服务端异常大页）。
  static const int maxItemsPerPage = 100;

  /// tab 结构（首拉成功时记录；重进时据此还原默认 tab/榜）。
  List<RankContent>? _contents;

  /// 榜页缓存：key = contentId + boardId。
  final Map<String, RankBoardPage> _pages = <String, RankBoardPage>{};

  /// 清空（测试用；服务端结构变更时也可整体丢弃）。
  void clear() {
    _contents = null;
    _pages.clear();
  }

  static String _keyOf(String contentId, String boardId) =>
      '$contentId\u001f$boardId';

  /// 上次成功的 tab 结构；null = 本会话还没有成功过。
  List<RankContent>? get contents => _contents;

  /// 某个 tab+榜的缓存页；null = 没有。
  RankBoardPage? pageOf(String contentId, String boardId) {
    if (contentId.isEmpty || boardId.isEmpty) return null;
    return _pages[_keyOf(contentId, boardId)];
  }

  /// 记录首拉结果（tab 结构 + 默认榜页）。
  void rememberFirst({
    required List<RankContent> contents,
    required String contentId,
    required String boardId,
    required List<RankItem> items,
    required String cursor,
    required bool hasMore,
  }) {
    _contents = contents;
    rememberPage(
      contentId: contentId,
      boardId: boardId,
      items: items,
      cursor: cursor,
      hasMore: hasMore,
    );
  }

  /// 记录切榜 / 下拉刷新的结果（覆盖对应榜页；tab 结构不变）。
  void rememberPage({
    required String contentId,
    required String boardId,
    required List<RankItem> items,
    required String cursor,
    required bool hasMore,
  }) {
    if (contentId.isEmpty || boardId.isEmpty) return;
    _pages[_keyOf(contentId, boardId)] = RankBoardPage(
      items: List<RankItem>.of(items.take(maxItemsPerPage)),
      cursor: cursor,
      hasMore: hasMore,
    );
  }
}
