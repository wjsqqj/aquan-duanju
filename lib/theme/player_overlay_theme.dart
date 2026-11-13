import 'dart:ui' show Color;
import 'package:flutter/painting.dart' show FontWeight, TextStyle;

/// 播放器 OSD 专用 Token（design.md §2 子任务③ / implement.md 3.1）。
///
/// **不与全站主题耦合**：OSD 永远叠在视频画面上，配色只取决于「压暗多少才
/// 能保住文字」，跟浅/深主题无关，所以这里是自足常量，不走 `context.app`。
/// 本文件在 `scripts/ui_style_audit.py` 的豁免清单里（Token 源头允许字面值）。
///
/// 电影化分层（替换旧「五档黑 + 四级白」临时阶梯）：
/// - scrim 三档——遮断强度递减，对应「用户必须读 / 可以扫 / 只是衬底」；
/// - 文字三档——玻璃/暗底上的信息层级；
/// - 控件尺寸两档——桌面触达 40/44，TV 放大档保持 28/18。
///
/// 三处播放端（主播放器 / 第三方源 / 投屏接收端）共用本类（AC3.2）。
abstract final class PlayerOverlayTokens {
  // ---- scrim 三档（整层压暗）----
  /// 0.82：错误页 / 起播准备层——用户必须停下来读的遮断层。
  static const Color scrimStrong = Color(0xD1000000);

  /// 0.58：缓冲徽标、静音提示——可以扫一眼的浮块。
  static const Color scrimMedium = Color(0x94000000);

  /// 0.32：控件可见时的整屏衬底——只帮文字压背景，不遮片。
  static const Color scrimSoft = Color(0x52000000);

  // ---- 局部填充（OSD pill / HUD / 菜单面板）----
  /// 0.66：中央 OSD 提示 pill（倍速切换、跳集回执）。
  static const Color pillFill = Color(0xA8000000);

  /// 0.54：手势 HUD pill（音量 / 亮度反馈）。
  static const Color hudFill = Color(0x8A000000);

  /// 「更多」菜单 / 下拉面板底（旧 `Colors.grey.shade900`）。
  static const Color panelFill = Color(0xFF161719);

  /// 视频区底色（无信号 / 信箱黑边；旧 `Colors.black` 直取）。
  static const Color videoBlack = Color(0xFF000000);

  // ---- 圆角 ----
  /// HUD / OSD pill 圆角（旧 24）。
  static const double radiusPill = 24;

  /// 错误 / 菜单面板圆角（旧 12）。
  static const double radiusPanel = 12;

  /// 缓冲徽标圆角（旧 20）。
  static const double radiusBadge = 20;

  /// 小块圆角（旧 8）。
  static const double radiusSm = 8;

  // ---- 文字三档（暗底 / 玻璃上）----
  /// 主文字：标题、当前值。
  static const Color textPrimary = Color(0xFFFFFFFF);

  /// 次级文字：说明、未激活项（旧 `Colors.white70`）。
  static const Color textSecondary = Color(0xB3FFFFFF);

  /// 三级文字：细节、错误详情（旧 `white54` / `white38` 归并）。
  static const Color textTertiary = Color(0x8AFFFFFF);

  // ---- 强调 ----
  /// 选中 / 警示强调（旧 `Colors.amberAccent`）。
  static const Color accent = Color(0xFFFFD740);

  /// 错误强调（面板红线 / 图标；旧 `Colors.redAccent`）。
  static const Color dangerLine = Color(0xFFFF5252);

  // ---- 控件尺寸 ----
  /// 桌面触达目标：次级图标按钮。
  static const double targetSm = 40;

  /// 桌面触达目标：主行按钮 / 进度条行。
  static const double targetLg = 44;

  /// TV 放大档图标（大）。
  static const double tvIconLg = 28;

  /// TV 放大档图标（小）。
  static const double tvIconSm = 18;

  /// 桌面基准字号（旧 14 直取）。
  static const double fontBase = 14;

  /// TV 放大档字号（旧 18 直取）。
  static const double tvFontLg = 18;

  // ---- 文字样式预设（颜色 + 字号一并钉住，保持 const 可用）----
  /// 15 / 主文字——面板标题、错误主文案。
  static const TextStyle stylePrimaryTitle = TextStyle(
    color: textPrimary,
    fontSize: 15,
    height: 1.4,
  );

  /// 15 / 600 / 主文字——起播准备层的剧名。
  static const TextStyle stylePrimaryTitleStrong = TextStyle(
    color: textPrimary,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  /// 中央 OSD 提示值（桌面 14 / 600）。
  static const TextStyle styleOsdValue = TextStyle(
    color: textPrimary,
    fontSize: fontBase,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  /// 中央 OSD 提示值（TV 放大档 18 / 600）。
  static const TextStyle styleOsdValueTv = TextStyle(
    color: textPrimary,
    fontSize: tvFontLg,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  /// 14 / 主文字——按钮行、菜单主行。
  static const TextStyle stylePrimaryBody = TextStyle(
    color: textPrimary,
    fontSize: fontBase,
    height: 1.4,
  );

  /// 13 / 主文字——次要标签。
  static const TextStyle stylePrimaryLabel = TextStyle(
    color: textPrimary,
    fontSize: 13,
    height: 1.4,
  );

  /// 12 / 主文字——说明行。
  static const TextStyle stylePrimaryCaption = TextStyle(
    color: textPrimary,
    fontSize: 12,
    height: 1.4,
  );

  /// 12 / 三级文字——错误详情、低亮度辅助（旧 `white38`/`white54` 归并）。
  static const TextStyle styleTertiaryCaption = TextStyle(
    color: textTertiary,
    fontSize: 12,
    height: 1.4,
  );

  /// 12 / 次级文字——说明行（第三方源 / 接收端 OSD）。
  static const TextStyle styleSecondaryCaption = TextStyle(
    color: textSecondary,
    fontSize: 12,
    height: 1.4,
  );

  /// 只带主文字色（字号随宿主）——菜单项、控件内文字。
  static const TextStyle stylePrimary = TextStyle(color: textPrimary);

  /// 只带次级文字色。
  static const TextStyle styleSecondary = TextStyle(color: textSecondary);

  /// 只带三级文字色。
  static const TextStyle styleTertiary = TextStyle(color: textTertiary);

  /// 只带强调色（旧 `Colors.amberAccent`）。
  static const TextStyle styleAccent = TextStyle(color: accent);
}
