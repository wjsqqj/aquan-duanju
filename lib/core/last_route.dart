import 'dart:convert';

/// 冷启动会话恢复：离开时停留的页面记录（11-19-ux-resume R1 + R1 扩展）。
///
/// 记录五类页面：详情页 / 播放页 / 帖子详情 / 社区页 / 新剧上新。写侧有两处：
/// - [LastRouteTracker]（导航观察者）：栈顶路由 arguments 是 [LastRoute]
///   就写 `ui.lastRoute`，回到其它页面（含首页壳层）清除；
/// - 播放页换集（不开新路由）在 `_openEpisode` 里刷新 episode。
/// 读侧只有恢复入口（home_screen 首帧后）：`ui.resumeSession` 开、记录
/// 存在且距 [LastRoute.at] 不足 [kLastRouteTtl]、本次启动无深链命令。
///
/// 编解码故意放在这里做成纯函数：设置备份（importBackup）也要用它校验，
/// 本文件不 import 任何 store/screen，避免反向依赖。
enum LastRouteKind { detail, player, post, community, releases }

/// 可恢复页面路由的 name（push 时挂在 RouteSettings 上，观察者靠它识别）。
const String kRouteNameDetail = 'detail';
const String kRouteNamePlayer = 'player';
const String kRouteNamePost = 'post';
const String kRouteNameCommunity = 'community';
const String kRouteNameReleases = 'releases';

/// 记录时效：隔天失效（kaixinguo-android 口径），超过就清除不再恢复。
const Duration kLastRouteTtl = Duration(hours: 24);

class LastRoute {
  const LastRoute({
    required this.kind,
    this.seriesId = '',
    this.episode = 0,
    this.postId = '',
    this.title = '',
    required this.at,
  });

  factory LastRoute.detail({required String seriesId, DateTime? at}) =>
      LastRoute(
        kind: LastRouteKind.detail,
        seriesId: seriesId,
        at: at ?? DateTime.now(),
      );

  factory LastRoute.player({
    required String seriesId,
    required int episode,
    DateTime? at,
  }) => LastRoute(
    kind: LastRouteKind.player,
    seriesId: seriesId,
    episode: episode,
    at: at ?? DateTime.now(),
  );

  /// 帖子详情（11-19-ux-resume-2 R1）：[title] 是列表页带来的占位标题，
  /// 恢复直落时详情页加载期间先显示它。
  factory LastRoute.post({
    required String postId,
    String title = '',
    DateTime? at,
  }) => LastRoute(
    kind: LastRouteKind.post,
    postId: postId,
    title: title,
    at: at ?? DateTime.now(),
  );

  factory LastRoute.community({DateTime? at}) =>
      LastRoute(kind: LastRouteKind.community, at: at ?? DateTime.now());

  factory LastRoute.releases({DateTime? at}) =>
      LastRoute(kind: LastRouteKind.releases, at: at ?? DateTime.now());

  final LastRouteKind kind;

  /// 详情 / 播放页对应的剧 id（post/community/releases 不用，恒空串）。
  final String seriesId;

  /// 播放页恢复的参考集号（集号从 1 开始；详情记录恒 0）。
  ///
  /// 恢复时只作参考：真正的断点（哪一集 + 哪一秒）以历史记录为准
  /// （复用既有续播机制，kaixinguo 口径「看到第几秒不存 session」）。
  final int episode;

  /// 帖子详情对应的帖子 id（仅 [LastRouteKind.post] 用）。
  final String postId;

  /// 帖子占位标题（仅 [LastRouteKind.post] 用；加载期间显示，可空）。
  final String title;

  /// 记录时刻（24h 时效判断用）。
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    if (seriesId.isNotEmpty) 'seriesId': seriesId,
    if (kind == LastRouteKind.player) 'episode': episode,
    if (postId.isNotEmpty) 'postId': postId,
    if (title.isNotEmpty) 'title': title,
    'at': at.millisecondsSinceEpoch,
  };

  String encode() => jsonEncode(toJson());

  /// 解析失败（非法 JSON / 未知结构 / 缺路由主键 / 未知 kind）返回 null，
  /// 调用方按「无记录」处理（设计口径：非法 JSON 忽略回空）。
  ///
  /// 向后兼容：新字段（postId/title）旧记录缺省按默认空串处理；旧记录
  /// 只有 detail/player 两种 kind，按各自必带的 seriesId 校验，不受影响。
  static LastRoute? tryDecode(String raw) {
    if (raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final String kindName = decoded['kind'] as String? ?? '';
    final LastRouteKind? kind = switch (kindName) {
      'detail' => LastRouteKind.detail,
      'player' => LastRouteKind.player,
      'post' => LastRouteKind.post,
      'community' => LastRouteKind.community,
      'releases' => LastRouteKind.releases,
      _ => null,
    };
    if (kind == null) return null;
    final String seriesId = decoded['seriesId'] as String? ?? '';
    final String postId = decoded['postId'] as String? ?? '';
    final String title = decoded['title'] as String? ?? '';
    // 路由主键按 kind 分检：detail/player 必须带 seriesId，post 必须带
    // postId，community/releases 页面自取数据没有主键。
    final bool hasKey = switch (kind) {
      LastRouteKind.detail || LastRouteKind.player => seriesId.isNotEmpty,
      LastRouteKind.post => postId.isNotEmpty,
      LastRouteKind.community || LastRouteKind.releases => true,
    };
    if (!hasKey) return null;
    final int atMs = decoded['at'] is int
        ? decoded['at'] as int
        : int.tryParse('${decoded['at']}') ?? 0;
    if (atMs <= 0) return null;
    return LastRoute(
      kind: kind,
      seriesId: seriesId,
      episode: decoded['episode'] is int ? decoded['episode'] as int : 0,
      postId: postId,
      title: title,
      at: DateTime.fromMillisecondsSinceEpoch(atMs),
    );
  }
}
