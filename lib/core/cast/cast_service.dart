import 'cast_controller.dart';
import 'cast_profile.dart';
import 'cast_recipe.dart';
import 'cast_target.dart';

/// 投屏全局单例：控制器跨页面存活（迷你窗/详情页切换不掉会话），
/// 设备记忆（最近/钉选）由调用方经 CastStore 持久化。
class CastService {
  CastService._();

  static final CastService instance = CastService._();

  final CastController controller = CastController();

  /// M3-4：把 CastStore 的配方/画像表接到控制器（修复配方持久化未接线，
  /// AC-14 跨启动命中依赖这里）。bootstrap 加载完 CastStore 后调用一次；
  /// 未调用时控制器用内存表（不落盘）。
  ///
  /// R1：[sessionRecorder] 传 `CastStore` 实例本身（实现
  /// [CastSessionRecorder]），投送成功/轮询/会话收尾写 `lastSession`
  /// 恢复记录；不传 = 不记录，「恢复上次投屏」入口不出现。
  void attachStores({
    required CastRecipeStore recipes,
    CastProfileStore? profiles,
    CastSessionRecorder? sessionRecorder,
  }) {
    controller.recipes = recipes;
    controller.profiles = profiles;
    controller.sessionRecorder = sessionRecorder;
  }

  /// 设备排序：钉选 > 最近使用 > 其它；同分按名称、再按 id 兜底（全序）。
  ///
  /// 在线状态**不参与排序**（11-09 用户反馈修复）：SSDP NOTIFY 会让设备反复
  /// 上下线，用它加权会让列表自己换位——现象就是「选中的设备一直变来变去」。
  /// 在线只影响图标置灰与「离线」标记。
  ///
  /// id 兜底是必需的：真实环境存在同名设备（两台「央视频电视投屏助手」、
  /// 两台「投屏电视Q3」，udn 与 IP 都不同），只比名称会返回 0，而 Dart 的
  /// `List.sort` 不保证稳定，同分项顺序每次 build 都可能不同。
  List<CastTarget> sortDevices(
    Iterable<CastTarget> devices, {
    required Set<String> pinnedIds,
    String? lastId,
  }) {
    final list = List.of(devices);
    int rank(CastTarget d) {
      if (pinnedIds.contains(d.id)) return 0;
      if (d.id == lastId) return 1;
      return 2;
    }

    list.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final byName = a.name.compareTo(b.name);
      if (byName != 0) return byName;
      // 全序的最后一环：id（DLNA=udn / Chromecast=host:port / AirPlay=deviceid）
      // 唯一且稳定，保证任意输入顺序下输出一致。
      return a.id.compareTo(b.id);
    });
    return list;
  }
}

/// 设备行副标题：`协议 · 型号 · IP`（型号为空时省略该段；离线再追加「离线」）。
///
/// IP 恒显示（11-09 用户选择）：同一台电视上常同时存在多个投屏接收端，且存在
/// 同名同型号的两台（不同 IP）——只给型号无法区分，用户会「点一个投到另一个」。
String castDeviceSubtitle(CastTarget d) {
  final protocol = switch (d.protocol) {
    CastProtocol.chromecast => 'Chromecast',
    CastProtocol.airplay => 'AirPlay',
    CastProtocol.dlna => 'DLNA',
  };
  return <String>[
    protocol,
    if (d.modelName.isNotEmpty) d.modelName,
    if (d.host.isNotEmpty) d.host,
    if (!d.online) '离线',
  ].join(' · ');
}
