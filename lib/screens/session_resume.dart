import 'package:flutter/material.dart';

import '../core/last_route.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import 'community_screen.dart';
import 'detail_screen.dart';
import 'post_detail_screen.dart';
import 'releases_screen.dart';

/// 冷启动会话恢复（11-19-ux-resume R1，11-19-ux-resume-2 扩展）的追踪与
/// 恢复入口。
///
/// 追踪选型：detail/player 的 push 调用点全库共 8 处（详情 5 + 播放 3），
/// 不算分散 → 按设计走主方案：push 调用点补 `RouteSettings(name:, arguments:)`，
/// 根 Navigator 挂 [LastRouteTracker] 观察；播放页换集不开新路由，由
/// PlayerScreen `_openEpisode` 集中点自报刷新 episode。
/// 11-19-ux-resume-2 把帖子详情（3 处）/ 社区页（2 处）/ 上新页（1 处）
/// 的 push 点纳入同一观察机制（arguments 带各自的 [LastRoute]）。

/// 「上次停留页」的导航观察者：栈顶是 detail/player（路由 arguments 带
/// [LastRoute]）就写 `ui.lastRoute`；回到其它页面（含首页壳层）就清除。
///
/// 弹窗 / 底部面板（PopupRoute）不算页面切换，忽略——在详情页上开个菜单
/// 不能把「上次停留」清掉。
class LastRouteTracker extends NavigatorObserver {
  LastRouteTracker(this._store);

  final SettingsStore _store;

  void _evaluate(Route<dynamic>? route) {
    if (route is! PageRoute) return;
    final Object? args = route.settings.arguments;
    if (args is LastRoute) {
      _store.uiLastRoute = args.encode();
      return;
    }
    _store.uiLastRoute = '';
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // 根路由的首次装载（MaterialApp home）也会发 didPush 且 previousRoute
    // 为 null：此时恢复入口还没读 lastRoute，不能当成「回到壳层」清键。
    if (previousRoute == null) return;
    _evaluate(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _evaluate(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _evaluate(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    // pushReplacement（跨季换页等）也走这里：观察的是新栈顶。
    _evaluate(newRoute);
  }
}

/// 恢复入口：home_screen 首帧（tab 恢复之后）调用一次。
class SessionResume {
  SessionResume._();

  /// 本次启动带导航命令（AI / 命令行 `--series` / `--watch` 深链）时置真：
  /// 深链优先，本次启动不做会话恢复。main.dart 在取走启动命令后设置。
  static bool suppressedByLaunchCommand = false;

  /// 按记录恢复上次停留的页面（11-19-ux-resume R1，11-19-ux-resume-2 扩展）。
  ///
  /// 恢复期间壳层照常渲染（先见首页再盖上目标页）。按 kind 分流：
  /// - 帖子 / 社区 / 上新：直接 push 目标页，页面自己拉数据（失败有
  ///   LoadView 错误态 + 重试入口，不是空转）。恢复入口不做预检 → 没有
  ///   可失败的步骤 → 没有「失败清键」路径；记录保留，下次启动按同一
  ///   语义再恢复。
  /// - detail/player：借道详情页——播放恢复把 `autoplay` 交给既有
  ///   「详情→播放」组装链路，断点由详情页的 `_resumeTarget`（历史 +
  ///   回退 3 秒）决定，不旁路续播机制；getSeries 预检失败静默清键。
  static Future<void> maybeResume(BuildContext context) async {
    if (suppressedByLaunchCommand) return;
    final scope = AppScope.read(context);
    final settings = scope.settings;
    if (!settings.uiResumeSession) return;
    final LastRoute? last = LastRoute.tryDecode(settings.uiLastRoute);
    if (last == null) return;
    if (DateTime.now().difference(last.at) >= kLastRouteTtl) {
      settings.uiLastRoute = ''; // 隔天失效：清掉旧记录，不恢复
      return;
    }
    // 让路守卫对所有 kind 同一不变式：栈顶不再是壳层（用户已自行导航）
    // 就放弃恢复不盖页。新三类分支到这里全程无 await，守卫是防御性的
    // （防后续重构在 push 前插入异步步骤时丢掉这条不变式）。
    if (!context.mounted || Navigator.of(context).canPop()) return;
    switch (last.kind) {
      case LastRouteKind.post:
      case LastRouteKind.community:
      case LastRouteKind.releases:
        final name = switch (last.kind) {
          LastRouteKind.post => kRouteNamePost,
          LastRouteKind.community => kRouteNameCommunity,
          _ => kRouteNameReleases,
        };
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: name, arguments: last),
            builder: (_) => switch (last.kind) {
              LastRouteKind.post => PostDetailScreen(
                postId: last.postId,
                title: last.title,
              ),
              LastRouteKind.community => const CommunityScreen(),
              _ => const ReleasesScreen(),
            },
          ),
        );
        return;
      case LastRouteKind.detail:
      case LastRouteKind.player:
        break;
    }
    try {
      await scope.history.ensureLoaded();
      final series = await scope.api.getSeries(last.seriesId);
      if (!context.mounted) return;
      // 慢网守卫：恢复拉取期间用户已自行导航（栈顶不再是壳层）就让路，
      // 不把迟到的恢复页盖在用户先点进的页面上。
      if (Navigator.of(context).canPop()) return;
      // 播放恢复接力时进历史记录的内容类型（继续观看分类不因恢复而漂移）。
      final contentType = scope.history.get(last.seriesId)?.contentType ?? '';
      // 路由 arguments 描述路由本身：播放恢复借道详情页，若把 player 记录
      // 原样挂上，用户从接力播放页退回详情页时追踪端会把旧播放记录写回，
      // 「已退出播放器」的意图被覆盖，24h 内每次重启都会再带声起播。
      final routeArgs = last.kind == LastRouteKind.player
          ? LastRoute.detail(seriesId: last.seriesId, at: last.at)
          : last;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: kRouteNameDetail, arguments: routeArgs),
          builder: (_) => DetailScreen(
            seriesId: last.seriesId,
            title: series.title,
            // 播放页恢复：详情加载完自动接力进播放页（详情→播放组装链路）。
            autoplay: last.kind == LastRouteKind.player,
            contentType: contentType,
          ),
        ),
      );
    } catch (_) {
      // 下架 / 网络失败：静默清键，下次启动不再尝试。
      settings.uiLastRoute = '';
    }
  }
}
