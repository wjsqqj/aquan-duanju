import 'dart:ui';

/// 窗口几何守卫。
///
/// 事故背景：最小化状态下关闭窗口时，Windows 报告的窗口几何是「最小化占位」
/// （位置约 (-32000,-32000)，尺寸 158×26）。如果原样落盘，下次启动窗口会被
/// 摆到屏幕外，用户看到「进程在、页面不显示」。
///
/// 两道防线都收口在这里，便于单测：
/// 1. 写入侧 [isPersistable]：最小化或尺寸小到不可能是真实窗口时不落盘；
/// 2. 读取侧 [sanitize]：尺寸过小回落默认值；位置与任何显示器工作区都没有
///    足够重叠时放弃位置（改为居中）——已被写坏配置的老用户升级后自动恢复。
abstract final class WindowGeometryGuard {
  /// 可信窗口尺寸下限：比它还小的只可能是最小化占位或销毁瞬间的脏读。
  static const Size minimumSize = Size(320, 180);

  /// 默认窗口尺寸（与首页 WindowOptions 保持一致）。
  static const Size defaultSize = Size(1180, 760);

  /// 窗口与工作区至少要重叠这么大，才算「用户看得见、拖得回来」。
  static const double _minVisibleWidth = 120;
  static const double _minVisibleHeight = 40;

  /// 浮点误差容忍：DPI 换算后常见 959.9999 / 960.0000001 这类值。
  static const double _epsilon = 1;

  /// 当前窗口几何是否值得落盘。
  static bool isPersistable({required bool minimized, required Size size}) {
    if (minimized) return false;
    if (!size.width.isFinite || !size.height.isFinite) return false;
    return size.width + _epsilon >= minimumSize.width &&
        size.height + _epsilon >= minimumSize.height;
  }

  /// 启动前清洗已保存的窗口几何。
  ///
  /// [workAreas] 为各显示器工作区（逻辑像素）；为空表示取不到显示器信息，
  /// 此时只剔除明显的最小化占位坐标（≤ -10000），不误伤多屏用户的负坐标副屏。
  static WindowGeometry sanitize(
    Rect? saved, {
    List<Rect> workAreas = const [],
  }) {
    if (saved == null) {
      return const WindowGeometry(size: defaultSize);
    }
    var width = saved.width;
    var height = saved.height;
    if (!width.isFinite ||
        !height.isFinite ||
        width + _epsilon < minimumSize.width ||
        height + _epsilon < minimumSize.height) {
      width = defaultSize.width;
      height = defaultSize.height;
    }

    final left = saved.left;
    final top = saved.top;
    var keepPosition = left.isFinite && top.isFinite;
    if (keepPosition) {
      if (workAreas.isEmpty) {
        keepPosition = left > -10000 && top > -10000;
      } else {
        final window = Rect.fromLTWH(left, top, width, height);
        keepPosition = workAreas.any((area) {
          final overlap = window.intersect(area);
          return overlap.width >= _minVisibleWidth &&
              overlap.height >= _minVisibleHeight;
        });
      }
    }
    return WindowGeometry(
      size: Size(width, height),
      position: keepPosition ? Offset(left, top) : null,
    );
  }
}

/// 清洗后的窗口几何：尺寸必填，位置为空表示居中。
class WindowGeometry {
  const WindowGeometry({required this.size, this.position});

  final Size size;
  final Offset? position;
}
