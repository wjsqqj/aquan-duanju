/// 播放页底栏的布局阈值。
///
/// 底栏固定子项：上一集 / 播放 / 下一集 / 选集 / 弹幕 / 更多 / 睡眠定时 /
/// 倍速 / 适应片源 / 铺满 / 迷你 / 横竖屏。IconButton 默认 48dp，睡眠与倍速
/// 另有文本内边距，全量约 700dp。
///
/// 两个阈值分工：
/// - [kCompactPlayerBarWidth]：低于它把睡眠定时与倍速收进「更多」（不再内联）；
/// - [kPlayerBarFullWidth]：低于它底栏改为横向滚动，否则最右侧按钮被裁掉
///   （用户实测「一半在屏幕外」、点不到）。
library;

/// 紧凑底栏阈值：睡眠定时与倍速收进「更多」。
const double kCompactPlayerBarWidth = 420;

/// 底栏完整排布阈值：低于此宽度底栏改为可横向滚动。
///
/// 桌面窗口可以拉得很窄，所以这里**不再按 desktop 放行**——窄窗和手机一样
/// 需要紧凑模式，否则倍速/睡眠按钮会跑到窗口外。
const double kPlayerBarFullWidth = 720;

/// 是否使用紧凑底栏：只看可用宽度，桌面窄窗同样紧凑。
///
/// [desktop] 保留在签名里只为不动调用点（历史语义「桌面永远不紧凑」已被
/// 用户实测推翻：桌面窗口拖窄后同样点不到倍速）。
bool useCompactPlayerBar({required bool desktop, required double width}) =>
    width < kCompactPlayerBarWidth;

/// 底栏是否需要横向滚动（可用宽度放不下全部按钮）。
bool useScrollablePlayerBar(double width) => width < kPlayerBarFullWidth;
