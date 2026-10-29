
import 'cast_controller.dart';
import 'dlna_device.dart';

/// 投屏全局单例：控制器跨页面存活（迷你窗/详情页切换不掉会话），
/// 设备记忆（最近/钉选）由调用方经 CastStore 持久化。
class CastService {
  CastService._();

  static final CastService instance = CastService._();

  final CastController controller = CastController();

  /// 设备排序：钉选 > 最近使用 > 在线 > 名称。
  List<DlnaDevice> sortDevices(
    Iterable<DlnaDevice> devices, {
    required Set<String> pinnedUdns,
    String? lastUdn,
  }) {
    final list = List.of(devices);
    int rank(DlnaDevice d) {
      if (pinnedUdns.contains(d.udn)) return 0;
      if (d.udn == lastUdn) return 1;
      return d.online ? 2 : 3;
    }

    list.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.friendlyName.compareTo(b.friendlyName);
    });
    return list;
  }
}
