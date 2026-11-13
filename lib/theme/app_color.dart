import 'package:flutter/widgets.dart';

// =============================================================================
// 色板（design.md §3 / §4.1–§4.3）
//
// 本文件是**全库唯一**允许出现 `Color(0x...)` 字面量的地方（§3 L1）。
// 新色值一律先加在 L1，再由 L2 的 `AppColors` 转发；widget / screen 只允许
// 引用 `AppColors`（或 `context.app.colors`），不得再写十六进制。
// =============================================================================

// ---------------------------------------------------------------------------
// L1 · 品牌橙阶（§4.1，暖橙，扩展现有 seed）
//
// 整条色阶按规范完整保留。L2 的 `AppColors` 目前只消费 400/500/600，
// 50/100/200/700 留给后续批次在 L2 增补「选中底 / 描边 / 深色强调」Token 时
// 引用；在被引用之前用 `unused_element` 忽略保持 analyze 零告警。
// ---------------------------------------------------------------------------

// ignore: unused_element
const _orange50 = Color(0xFFFFF2EC); // 浅色下强调底
// ignore: unused_element
const _orange100 = Color(0xFFFFE0D1); // 选中底（浅）
// ignore: unused_element
const _orange200 = Color(0xFFFFC4A8); // 描边（浅）
const _orange400 = Color(0xFFFF8C5C); // hover 亮阶
const _orange500 = Color(0xFFFF7A45); // 品牌主色（= AppTheme.seed，不得改动）
const _orange600 = Color(0xFFF05F27); // pressed
// ignore: unused_element
const _orange700 = Color(0xFFC94815); // 深色下文字强调

// ---------------------------------------------------------------------------
// L1 · 中性阶（§4.2 表面 / §4.3 文字；0 最亮 → 1000 最暗）
// ---------------------------------------------------------------------------

const _neutral0 = Color(0xFFFFFFFF); // #FFFFFF
const _neutral50 = Color(0xFFFAF7F5); // #FAF7F5
const _neutral100 = Color(0xFFF4EFEB); // #F4EFEB
const _neutral150 = Color(0xFFF2EFED); // #F2EFED
const _neutral200 = Color(0xFFE6DFD9); // #E6DFD9
const _neutral300 = Color(0xFFA6A19D); // #A6A19D
const _neutral350 = Color(0xFF7C756F); // #7C756F —— 浅色 `outline`（4.55:1，可作次要文字）
const _neutral400 = Color(0xFF96908A); // #96908A
const _neutral450 = Color(0xFF8E8985); // #8E8985 —— 深色 `outline`（5.7:1，可作次要文字）
const _neutral500 = Color(0xFF736E6A); // #736E6A
const _neutral600 = Color(0xFF5F5852); // #5F5852
const _neutral800 = Color(0xFF222327); // #222327
const _neutral850 = Color(0xFF191A1D); // #191A1D
const _neutral900 = Color(0xFF121214); // #121214
const _neutral950 = Color(0xFF0A0A0B); // #0A0A0B
// ignore: unused_element
const _neutral1000 = Color(0xFF000000); // #000000

/// `hairline`（深色）在规范里写作 `#FFFFFF12`，即白 7% 透明度；
/// Flutter 的 8 位十六进制是 `AARRGGBB`，所以 alpha 提到最高两位。
const _hairlineDark = Color(0x12FFFFFF);

// ---------------------------------------------------------------------------
// L1 · 语义色（§4.3，深/浅两档）
// ---------------------------------------------------------------------------

const _successDark = Color(0xFF4CC38A);
const _successLight = Color(0xFF14804A);
const _warningDark = Color(0xFFE5B34D);
const _warningLight = Color(0xFFA66A00);
const _dangerDark = Color(0xFFFF6B5B);
const _dangerLight = Color(0xFFC13515);
const _infoDark = Color(0xFF6BA6FF);
const _infoLight = Color(0xFF1668C1);

// ---------------------------------------------------------------------------
// L2 · 语义 Token
// ---------------------------------------------------------------------------

/// L2 语义色（§3）。UI 只表达「这是正文 / 这是表面 / 这是品牌色」，
/// 不表达具体色相；深浅两套由 [light] / [dark] 提供。
@immutable
class AppColors {
  const AppColors({
    required this.canvas,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.hairline,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.brand,
    required this.brandHover,
    required this.brandPressed,
    required this.onBrand,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.focusRing,
  });

  /// 页面背景。
  final Color canvas;

  /// 卡片表面。
  final Color surface1;

  /// 抬升块 / 输入框。
  final Color surface2;

  /// 弹窗 / 抽屉。
  final Color surface3;

  /// 1px 分隔线与卡片描边（**只做分隔线，不可当文字色**）。
  final Color hairline;

  /// 描边 / 次要文字（对应 M3 `outline`）。
  ///
  /// 项目里有大量既有代码把 `colorScheme.outline` 当「淡文字」用（未选中的
  /// tab 标签、卡片副标题等）。因此这个角色必须**同时**满足「能当文字读」
  /// 与「能当描边看」：浅色 4.55:1、深色 5.7:1。分隔线请用 [hairline]。
  final Color outline;

  /// 正文。
  final Color textPrimary;

  /// 次要正文。
  final Color textSecondary;

  /// 辅助信息（仅限 ≥12px，且不承载唯一语义）。
  final Color textTertiary;

  /// 品牌主色 / 主按钮 / 进度条（恒为 `#FF7A45`）。
  final Color brand;

  /// 品牌 hover 态。
  final Color brandHover;

  /// 品牌 pressed 态。
  final Color brandPressed;

  /// 品牌底之上的文字/图标（主按钮内文字）。
  final Color onBrand;

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;

  /// 焦点环（2px 外扩）。
  final Color focusRing;

  /// 浅色（`ThemeData.light()` 使用）。
  static const AppColors _light = AppColors(
    canvas: _neutral50,
    surface1: _neutral0,
    surface2: _neutral100,
    surface3: _neutral0,
    hairline: _neutral200,
    outline: _neutral350,
    textPrimary: _neutral900,
    textSecondary: _neutral600,
    textTertiary: _neutral400,
    brand: _orange500,
    brandHover: _orange400,
    brandPressed: _orange600,
    onBrand: _neutral0,
    success: _successLight,
    warning: _warningLight,
    danger: _dangerLight,
    info: _infoLight,
    focusRing: _orange600,
  );

  /// 深色（`ThemeData.dark()` 使用）。
  static const AppColors _dark = AppColors(
    canvas: _neutral950,
    surface1: _neutral900,
    surface2: _neutral850,
    surface3: _neutral800,
    hairline: _hairlineDark,
    outline: _neutral450,
    textPrimary: _neutral150,
    textSecondary: _neutral300,
    textTertiary: _neutral500,
    brand: _orange500,
    brandHover: _orange400,
    brandPressed: _orange600,
    onBrand: _neutral0,
    success: _successDark,
    warning: _warningDark,
    danger: _dangerDark,
    info: _infoDark,
    focusRing: _orange400,
  );

  /// 浅色 Token 集。
  static AppColors light() => _light;

  /// 深色 Token 集。
  static AppColors dark() => _dark;

  /// 按 [Brightness] 取色（`Theme.of(context).brightness` 场景）。
  static AppColors of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  /// 供 `AppTokens.lerp` 使用：把 [this] 向 [other] 插值 [t]（0 = 本套，1 = [other]）。
  AppColors lerpFrom(AppColors other, double t) {
    if (t <= 0) return this;
    if (t >= 1) return other;
    return AppColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface1: Color.lerp(surface1, other.surface1, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      brandHover: Color.lerp(brandHover, other.brandHover, t)!,
      brandPressed: Color.lerp(brandPressed, other.brandPressed, t)!,
      onBrand: Color.lerp(onBrand, other.onBrand, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
    );
  }
}
