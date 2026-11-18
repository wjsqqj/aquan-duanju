import 'dart:convert';

/// 冷启动会话恢复：离开时停留的页面记录（11-19-ux-resume R1）。
///
/// 只记录详情页 / 播放页两种（PRD 口径）。写侧有两处：
/// - [LastRouteTracker]（导航观察者）：detail/player 路由 push / 回壳层清除；
/// - 播放页换集（不开新路由）在 `_openEpisode` 里刷新 episode。
/// 读侧只有恢复入口（home_screen 首帧后）：`ui.resumeSession` 开、记录
/// 存在且距 [LastRoute.at] 不足 [kLastRouteTtl]、本次启动无深链命令。
///
/// 编解码故意放在这里做成纯函数：设置备份（importBackup）也要用它校验，
/// 本文件不 import 任何 store/screen，避免反向依赖。
enum LastRouteKind { detail, player }

/// 详情/播放页路由的 name（push 时挂在 RouteSettings 上，观察者靠它识别）。
const String kRouteNameDetail = 'detail';
const String kRouteNamePlayer = 'player';

/// 记录时效：隔天失效（kaixinguo-android 口径），超过就清除不再恢复。
const Duration kLastRouteTtl = Duration(hours: 24);

class LastRoute {
  const LastRoute({
    required this.kind,
    required this.seriesId,
    this.episode = 0,
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

  final LastRouteKind kind;

  /// 详情 / 播放页对应的剧 id。
  final String seriesId;

  /// 播放页恢复的参考集号（集号从 1 开始；详情记录恒 0）。
  ///
  /// 恢复时只作参考：真正的断点（哪一集 + 哪一秒）以历史记录为准
  /// （复用既有续播机制，kaixinguo 口径「看到第几秒不存 session」）。
  final int episode;

  /// 记录时刻（24h 时效判断用）。
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'seriesId': seriesId,
    if (kind == LastRouteKind.player) 'episode': episode,
    'at': at.millisecondsSinceEpoch,
  };

  String encode() => jsonEncode(toJson());

  /// 解析失败（非法 JSON / 未知结构 / 空 seriesId）返回 null，调用方按
  /// 「无记录」处理（设计口径：非法 JSON 忽略回空）。
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
      _ => null,
    };
    if (kind == null) return null;
    final String seriesId = decoded['seriesId'] as String? ?? '';
    if (seriesId.isEmpty) return null;
    final int atMs = decoded['at'] is int
        ? decoded['at'] as int
        : int.tryParse('${decoded['at']}') ?? 0;
    if (atMs <= 0) return null;
    return LastRoute(
      kind: kind,
      seriesId: seriesId,
      episode: decoded['episode'] is int ? decoded['episode'] as int : 0,
      at: DateTime.fromMillisecondsSinceEpoch(atMs),
    );
  }
}
