import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// =============================================================================
// 液态玻璃 Token（父任务 design.md §11.3 表格 / §12 边界，仓库根 DESIGN.md）
//
// 本文件是**唯一**允许出现玻璃材质参数的地方：
//   · 三档（nav / overlay / immersive）各自锁定的 8 个参数；
//   · 材质代际基线 `GlassStyle.ios26`（全库只在这里出现一次）；
//   · 玻璃「底托」的透明度。
//
// 取值与 §11.3 表格逐项一致，八参数之外（`frostOpacity` / `frostClamp` /
// `frostWeight` / `blurWeight` / `edgeAbsorption` / `rimLight` / `bodyShade` /
// `lensModel` / `refractiveIndex` …）一律保持上游默认，不在本层覆盖。
//
// 业务代码只经 `AppGlass`（`lib/widgets/glass/app_glass.dart`）与
// [settingsFor] 取用，不 import 上游类型、不写裸 `LiquidGlassSettings`。
// =============================================================================

/// 玻璃档位：调用点只选档位，参数取值全部由本文件决定。
enum AppGlassTier {
  /// 导航：NavigationRail 项 / 底部 Bar / 工具栏。
  nav,

  /// 浮层：Dialog / ModalSheet / ActionSheet / ContextMenu / Toast / 选集面板。
  overlay,

  /// 沉浸：播放器 OSD 带、投屏面板。恒深色 tint（叠在播放器 scrim 上）。
  immersive,
}

// ---------------------------------------------------------------------------
// glassColor（§11.3 表格最右列）
//
// 这是**上游材质色调**而不是 UI 表面色，所以留在本文件而不进
// `app_color.dart`（那里只放全站 canvas / surface / 文字 / 语义色）。
// ---------------------------------------------------------------------------

const Color _navTintDark = Color(0x0FFFFFFF);
const Color _navTintLight = Color(0x24FFFFFF);
const Color _overlayTintDark = Color(0x14FFFFFF);
const Color _overlayTintLight = Color(0x33FFFFFF);

/// 沉浸档恒深色，深浅主题共用。
const Color _immersiveTint = Color(0x33000000);

// ---------------------------------------------------------------------------
// 三档 × 深/浅
//
// [GlassThemeSettings] 是 const 且 glassColor 只有一档色值，所以深浅各存一份
// 常量，由 [resolveNav] / [resolveOverlay] 按当前亮度挑一个。
// ---------------------------------------------------------------------------

/// `glassNav` · 深色：thickness 18 / blur 14 / frost 18 / CA 0.008 / sat 1.4 /
/// 光 0.55 / 阴影 0.6。（blur/frost 增强：用户实测「磨砂感不足」）
const GlassThemeSettings _navDark = GlassThemeSettings(
  glassColor: _navTintDark,
  thickness: 18,
  blur: 14,
  frost: 18,
  chromaticAberration: 0.008,
  saturation: 1.4,
  lightIntensity: 0.55,
  shadowElevation: 0.6,
);

/// `glassNav` · 浅色（同深色，仅 glassColor 不同）。
const GlassThemeSettings _navLight = GlassThemeSettings(
  glassColor: _navTintLight,
  thickness: 18,
  blur: 14,
  frost: 18,
  chromaticAberration: 0.008,
  saturation: 1.4,
  lightIntensity: 0.55,
  shadowElevation: 0.6,
);

/// `glassOverlay` · 深色：thickness 24 / blur 6 / frost 14 / CA 0.012 / sat 1.5 /
/// 光 0.70 / 阴影 1.2。
const GlassThemeSettings _overlayDark = GlassThemeSettings(
  glassColor: _overlayTintDark,
  thickness: 24,
  blur: 6,
  frost: 14,
  chromaticAberration: 0.012,
  saturation: 1.5,
  lightIntensity: 0.70,
  shadowElevation: 1.2,
);

/// `glassOverlay` · 浅色（同深色，仅 glassColor 不同）。
const GlassThemeSettings _overlayLight = GlassThemeSettings(
  glassColor: _overlayTintLight,
  thickness: 24,
  blur: 6,
  frost: 14,
  chromaticAberration: 0.012,
  saturation: 1.5,
  lightIntensity: 0.70,
  shadowElevation: 1.2,
);

/// `glassImmersive`：thickness 14 / blur 8 / frost 6 / CA 0.006 / sat 1.2 /
/// 光 0.45 / 阴影 0.4，tint 恒深色。
const GlassThemeSettings _immersive = GlassThemeSettings(
  glassColor: _immersiveTint,
  thickness: 14,
  blur: 8,
  frost: 6,
  chromaticAberration: 0.006,
  saturation: 1.2,
  lightIntensity: 0.45,
  shadowElevation: 0.4,
);

/// `glassNav`（§11.3）：NavigationRail / 底部 Bar / 工具栏。
GlassThemeSettings resolveNav(Brightness brightness) =>
    brightness == Brightness.dark ? _navDark : _navLight;

/// `glassOverlay`（§11.3）：Dialog / ModalSheet / ActionSheet / ContextMenu /
/// Toast / 选集面板。
GlassThemeSettings resolveOverlay(Brightness brightness) =>
    brightness == Brightness.dark ? _overlayDark : _overlayLight;

/// `glassImmersive`（§11.3）：播放器 OSD 带 / 投屏面板。
///
/// 三档里唯一与亮度无关的一档——它恒深色，所以 [brightness] 不参与取值；
/// 参数保留是为了让 [settingsFor] 的签名统一，调用点不需要记特例。
GlassThemeSettings resolveImmersive(Brightness brightness) => _immersive;

/// 按档位取参数（[AppGlass] 的唯一入口）。
GlassThemeSettings settingsFor(AppGlassTier tier, Brightness brightness) =>
    switch (tier) {
      AppGlassTier.nav => resolveNav(brightness),
      AppGlassTier.overlay => resolveOverlay(brightness),
      AppGlassTier.immersive => resolveImmersive(brightness),
    };

// ---------------------------------------------------------------------------
// 底托（§11.3 末条 / §12）
//
// 玻璃本身不保证文字对比度：背景一旦透出，`textPrimary` / `textSecondary`
// 就可能被打穿。所以两条分支（折射 / 降级）都在玻璃之上、内容之下再叠一层
// `colors.surface3` 半透明，透明度取 §11.3 的两个示例底托色
// （深 `0x1A0A0A0B`、浅 `0x33FFFFFF`）；色相仍由 Token 提供。
// ---------------------------------------------------------------------------

/// 底托透明度 · 深色：`0x1A`（约 10%）。
const double kGlassBackingAlphaDark = 0x1A / 0xFF;

/// 底托透明度 · 浅色：`0x33`（约 20%）。
const double kGlassBackingAlphaLight = 0x33 / 0xFF;

/// 底托色：把 `colors.surface3` 按亮度调成半透明。
Color glassBacking(Color surface3, Brightness brightness) =>
    surface3.withValues(
      alpha: brightness == Brightness.dark
          ? kGlassBackingAlphaDark
          : kGlassBackingAlphaLight,
    );

// ---------------------------------------------------------------------------
// 全局基线（`LiquidGlassWidgets.wrap(theme: …)`）
// ---------------------------------------------------------------------------

/// 全站玻璃主题基线。
///
/// 基线只做「全站共同」的事：把材质代际钉在 [GlassStyle.ios26]（用户要的
/// iOS 液态玻璃），深浅两档沿用上游 iOS 26 预设本身——**三档差异不放在这里**
/// （由 [settingsFor] 在构建时现取），`saturation` / `refractiveIndex` /
/// `lensModel` 也保持上游取值，本层不额外覆盖。
GlassThemeData glassThemeData() => const GlassThemeData(
  style: GlassStyle.ios26,
  light: GlassThemeVariant(settings: GlassThemeSettings.ios26Light),
  dark: GlassThemeVariant(settings: GlassThemeSettings.ios26Dark),
);
