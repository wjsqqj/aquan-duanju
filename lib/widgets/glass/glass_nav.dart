import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../ui/app_interactive.dart';
import 'app_glass.dart';

// =============================================================================
// 玻璃导航（父任务 design.md §11.3 / implement.md 1b.5）
//
// 外壳的导航是允许常驻玻璃的位置之一（§11.6 单屏玻璃面预算 ≤ 6，实际只用了
// 「Rail 选中项」与「窄窗底部 Bar」两块）：
//   · 宽形态：Rail 里**当前选中项**一块玻璃面，未选中项保持实体表面；
//   · 窄形态：底部 `NavigationBar` 一整条玻璃面。
//
// 玻璃只负责「面」：四态（hover / pressed / focus / disabled）与选中语义一律
// 交回批次①的 [AppInteractive]，不在这里另开一套 `InkWell` 水波纹——否则同一个
// 外壳里会出现两种交互语言（D5）。
// =============================================================================

/// 玻璃导航项：宽形态 `NavigationRail` 里的单个 tab。
///
/// 结构上玻璃放在 [AppInteractive] **内部、图标之下**，而不是反过来包住它。
/// 原因是 [AppInteractive] 的四态底色用的是不透明的 `surface1` / `surface2`
/// （批次①的既有契约），玻璃若包在它外面会被整块盖住，等于白加。放进它的
/// `child` 之后：
/// - 描边仍由 [AppInteractive] 画在最外层，focus 时加粗到 2px 依然可读；
/// - hover / pressed / selected 的底色变化透过玻璃底托仍能看出深浅，选中时还有
///   `brand` @40% 描边这层强提示，与批次①的选中语言一致；
/// - 玻璃的祖先链上没有 `Opacity` / `ClipRect` / `BackdropFilter`（§11.5 第 1 条）；
///   唯一的 `Transform` 是 [AppInteractive] 的按下缩放，静止时为恒等变换、
///   按下时只有 0.985 的瞬态缩放，不影响采样。（该项恒为可用态，不会出现
///   `disabled` 的 `Opacity(0.5)`。）
class GlassRailItem extends StatelessWidget {
  const GlassRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.size,
    this.glassPill = true,
  });

  /// 图标，调用方一律取 `AppIcons`（全库唯一图标集）。
  final IconData icon;

  /// 中文标签，同时作为 `Tooltip` 文案。
  final String label;

  /// 是否是当前 tab：只有选中项铺玻璃面。
  final bool selected;

  /// 点按回调；语义与 `NavigationRailDestination` 的选中回调一致。
  final VoidCallback onTap;

  /// 图标边长；`null` 取 `metrics.s24`（电视形态由外壳传 `s32`）。
  final double? size;

  /// 选中项是否自己铺一块玻璃面。
  ///
  /// 整条 Rail 已经是玻璃时（[GlassRailSurface]）必须传 `false`：玻璃叠玻璃会让
  /// 后景被连续折射两次，边缘出现一道明显的重影接缝。此时选中态靠
  /// [AppInteractive] 的 `surface2` 底 + `brand` 描边表达，已经足够。
  final bool glassPill;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final double iconSize = size ?? m.s24;
    final Widget glyph = Icon(icon, size: iconSize);

    // 胶囊内边距：24 图标 + 上下各 4 = 32 高、左右各 16 = 56 宽，与 M3 原生
    // 指示器同尺寸——换成玻璃后外壳高度不变。
    final EdgeInsetsGeometry padding = EdgeInsets.fromLTRB(
      m.s16,
      m.s4,
      m.s16,
      m.s4,
    );

    return AppInteractive(
      onTap: onTap,
      selected: selected,
      tooltip: label,
      radius: BorderRadius.all(Radius.circular(m.radiusSm)),
      // 选中项把内边距挪到玻璃内部（内层 `Padding`），玻璃才能铺满整块可点区域；
      // 未选中项维持批次①的写法，几何尺寸两者完全一致。
      padding: selected && glassPill ? null : padding,
      child: selected && glassPill
          ? Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Positioned.fill(
                  // 玻璃不参与命中测试：点按 / 焦点全部由外层 AppInteractive 收，
                  // 避免玻璃里的 `BackdropFilter` 抢 hit test。
                  child: IgnorePointer(
                    child: AppGlass(
                      tier: AppGlassTier.nav,
                      radius: m.radiusSm,
                      child: const SizedBox.shrink(),
                    ),
                  ),
                ),
                Padding(padding: padding, child: glyph),
              ],
            )
          : glyph,
    );
  }
}

/// 玻璃导航面：把整条 `NavigationRail` 变成一块玻璃，并在它**背后**铺一层
/// 装饰背景。
///
/// 为什么必须有这层背景：玻璃只有在「背后有东西」时才看得见折射。外壳的 Rail
/// 直接坐在不透明的 `canvas` 上，背后是纯色 —— 玻璃采样到纯色，观感与实体面板
/// 完全一致（第一版实测截图就是这个问题）。所以这里先在 Rail 区域内画暖色渐变
/// 与两团品牌色光斑，玻璃隔着它采样，才有厚度、边缘高光与色散。
///
/// 该背景**只存在于 Rail 这一列**，不影响内容区任何页面；它属于「舞台灯光」而不是
/// 全站表面，因此不进 `AppColors`（§12 的表面体系只有 canvas + surface1..3）。
class GlassRailSurface extends StatelessWidget {
  const GlassRailSurface({super.key, required this.child});

  /// `NavigationRail` 本体（调用方需把它的 `backgroundColor` 设为透明）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const Positioned.fill(
          child: IgnorePointer(child: _RailBackdrop()),
        ),
        AppGlass(tier: AppGlassTier.nav, radius: 0, child: child),
      ],
    );
  }
}

/// Rail 背后的舞台灯光：暖色渐变 + 两团模糊光斑。
class _RailBackdrop extends StatelessWidget {
  const _RailBackdrop();

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final Color brand = tokens.colors.brand;
    final Color info = tokens.colors.info;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[tokens.colors.canvas, tokens.colors.surface2],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: -80,
            left: -70,
            child: _GlowBlob(size: 240, color: brand.withValues(alpha: 0.45)),
          ),
          Positioned(
            bottom: 60,
            left: -90,
            child: _GlowBlob(size: 220, color: info.withValues(alpha: 0.25)),
          ),
        ],
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      // 模糊只作用于背景层，不构成玻璃的祖先（§11.5 第 1 条）。
      imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

/// 玻璃底板版的底部导航：包住窄窗用的 `NavigationBar`。
///
/// 只换「面」，不碰语义：`selectedIndex` / `destinations` /
/// `onDestinationSelected` 全部由调用方原样传给 [NavigationBar]，本组件既不读
/// 也不改写，`labelBehavior`、指示器形状、图标配色继续来自 `navigationBarTheme`。
class GlassNavigationBar extends StatelessWidget {
  const GlassNavigationBar({super.key, required this.child, this.radius});

  /// 通常是外壳里的 `NavigationBar` 本体。
  final Widget child;

  /// 玻璃圆角；`null` 取 `metrics.radiusLg`。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;

    // 底部安全区（手势条）：`NavigationBar` 会自己读 `MediaQuery.padding.bottom`
    // 并把它加进高度。玻璃要贴到屏幕底边、内容又不许压到手势条，所以把这段
    // 安全区**挪到玻璃外面**：先 `removePadding` 让 Bar 只剩主题里的 s64，
    // 再由外层 `padding` 把留白补回来。
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    final NavigationBarThemeData navTheme = NavigationBarTheme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(m.s8, 0, m.s8, m.s8 + bottomInset),
      child: AppGlass(
        tier: AppGlassTier.nav,
        radius: radius ?? m.radiusLg,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          // `navigationBarTheme` 的底色是不透明的 `canvas`，铺在玻璃上会把玻璃
          // 整块盖掉。这里只把「面」改成透明，图标 / 指示器 / 标签配色不重写。
          child: NavigationBarTheme(
            data: navTheme.copyWith(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
