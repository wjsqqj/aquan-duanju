import 'package:flutter/widgets.dart';

/// 间距/圆角刻度的**原始常量**层：const 上下文（const EdgeInsets /
/// const BoxDecoration）里取值只能走这里——实例属性（`AppMetrics().s24`）
/// 不是 const 可求值的。`AppMetrics` 的实例字段默认值引用本层，单一事实源。
abstract final class AppSpacing {
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;
  static const double s64 = 64;
  static const double radiusXs = 4;
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;
}

/// 光晕 Token（design.md §4.6 白名单）。
///
/// 全库只允许存在 3 个实例：[AppMetrics.brandGlowSoft] /
/// [AppMetrics.brandGlowStrong] / [AppMetrics.brandGlowPulse]。
/// 构造函数私有，禁止在别处造第四处光晕，也禁止派生通用「任意强度」工厂。
@immutable
class BrandGlow {
  const BrandGlow._({
    required this.opacity,
    required this.radiusFactor,
    required this.blurRadius,
    this.pulsePeriod,
  });

  /// brand 的透明度档位（0.28 / 0.36）。
  final double opacity;

  /// 径向渐变半径相对容器短边的倍数（Flutter `RadialGradient.radius` 语义：
  /// 正是「绘制盒短边」的倍数）。
  final double radiusFactor;

  /// 外发光模糊半径（dp）；0 表示只做渐变、不做模糊。
  final double blurRadius;

  /// 呼吸周期；`null` 表示常亮不呼吸。
  final Duration? pulsePeriod;

  /// 光晕色：由当前主题的 `colors.brand` 派生，深/浅两套一致。
  Color tint(Color brand) => brand.withValues(alpha: opacity);

  /// 径向渐变：`brand @opacity` → 透明。
  RadialGradient gradient(Color brand) => RadialGradient(
    colors: <Color>[tint(brand), brand.withValues(alpha: 0)],
    radius: radiusFactor,
  );

  /// 同上，但光心锚在 [Alignment] 上（如 `Alignment(0, -1.6)` = 顶部中央的
  /// 舞台顶灯）。强度 / 半径仍由本 Token 钉住，调用点只选光源位置。
  RadialGradient gradientAt(Color brand, Alignment center) => RadialGradient(
    center: center,
    colors: <Color>[tint(brand), brand.withValues(alpha: 0)],
    radius: radiusFactor,
  );

  /// 外发光阴影（播放器主操作按钮用）。
  BoxShadow shadow(Color brand) =>
      BoxShadow(color: tint(brand), blurRadius: blurRadius);
}

// -----------------------------------------------------------------------------
// §4.6 光晕三件套（唯三实例，均为 const，可直接用在 const 构造里）
// -----------------------------------------------------------------------------

/// 发现页头图 / 继续观看横幅：径向渐变 orange500 @28% → 透明，半径 = 短边 ×1.2。
const BrandGlow _brandGlowSoft = BrandGlow._(
  opacity: 0.28,
  radiusFactor: 1.2,
  blurRadius: 0,
);

/// 播放器主操作（播放 / 重播）：外发光 orange500 @36%，模糊 24。
const BrandGlow _brandGlowStrong = BrandGlow._(
  opacity: 0.36,
  radiusFactor: 1,
  blurRadius: 24,
);

/// 沉浸态指示（全屏 / 投屏连接中）：呼吸 2 次/秒，respect reduceMotion。
const BrandGlow _brandGlowPulse = BrandGlow._(
  opacity: 0.36,
  radiusFactor: 1,
  blurRadius: 24,
  pulsePeriod: Duration(milliseconds: 500),
);

/// 度量 Token（design.md §4.5）：间距刻度、圆角、描边、动效、光晕。
///
/// 全部取值与亮度无关，深浅两套相同；`const AppMetrics()` 即标准一套，
/// [standard] 是它的具名实例。
@immutable
class AppMetrics {
  const AppMetrics({
    this.s2 = AppSpacing.s2,
    this.s4 = AppSpacing.s4,
    this.s6 = AppSpacing.s6,
    this.s8 = AppSpacing.s8,
    this.s12 = AppSpacing.s12,
    this.s16 = AppSpacing.s16,
    this.s20 = AppSpacing.s20,
    this.s24 = AppSpacing.s24,
    this.s32 = AppSpacing.s32,
    this.s40 = AppSpacing.s40,
    this.s48 = AppSpacing.s48,
    this.s64 = AppSpacing.s64,
    this.radiusXs = AppSpacing.radiusXs,
    this.radiusSm = AppSpacing.radiusSm,
    this.radiusMd = AppSpacing.radiusMd,
    this.radiusLg = AppSpacing.radiusLg,
    this.radiusXl = AppSpacing.radiusXl,
    this.radiusPill = 999,
    this.hairline = 1,
    this.focusRing = 2,
    this.micro = const Duration(milliseconds: 120),
    this.hover = const Duration(milliseconds: 150),
    this.enter = const Duration(milliseconds: 200),
    this.panel = const Duration(milliseconds: 250),
    this.page = const Duration(milliseconds: 300),
    this.microCurve = Curves.easeOutCubic,
    this.hoverCurve = Curves.easeOut,
    this.enterCurve = Curves.easeOutCubic,
    this.panelCurve = Curves.easeOutCubic,
    this.pageCurve = Curves.easeInOutCubic,
    this.brandGlowSoft = _brandGlowSoft,
    this.brandGlowStrong = _brandGlowStrong,
    this.brandGlowPulse = _brandGlowPulse,
    this.fxWordFlip = const Duration(milliseconds: 400),
    this.fxWordHold = const Duration(milliseconds: 1500),
  });

  /// 标准一套（深浅共用）。
  static const AppMetrics standard = AppMetrics();

  // ---- 间距刻度（§4.5：刻度外的值禁止出现在布局中）----
  final double s2;
  final double s4;
  final double s6;
  final double s8;
  final double s12;
  final double s16;
  final double s20;
  final double s24;
  final double s32;
  final double s40;
  final double s48;
  final double s64;

  // ---- 圆角 ----
  /// 4：小控件 / 标签。
  final double radiusXs;

  /// 8：输入框 / chip。
  final double radiusSm;

  /// 12：卡片（保持既有观感）。
  final double radiusMd;

  /// 16：面板 / 弹窗。
  final double radiusLg;

  /// 24：大容器。
  final double radiusXl;

  /// 999：胶囊 / 头像。
  final double radiusPill;

  // ---- 描边 ----
  /// 1px 分隔线与卡片描边。
  final double hairline;

  /// 焦点环（外扩 2）。
  final double focusRing;

  // ---- 动效时长（§4.5 表格）----
  /// 120ms：图标 / 角标状态切换。
  final Duration micro;

  /// 150ms：hover / pressed 反馈。
  final Duration hover;

  /// 200ms：卡片入场、展开。
  final Duration enter;

  /// 250ms：弹窗 / 底部面板。
  final Duration panel;

  /// 300ms：路由转场。
  final Duration page;

  // ---- 动效曲线 ----
  final Curve microCurve; // easeOutCubic
  final Curve hoverCurve; // easeOut
  final Curve enterCurve; // easeOutCubic
  final Curve panelCurve; // easeOutCubic
  final Curve pageCurve; // easeInOutCubic

  // ---- 光晕（§4.6，唯三 Token）----
  /// 发现页头图 / 继续观看横幅。
  final BrandGlow brandGlowSoft;

  /// 播放器主操作（播放 / 重播）。
  final BrandGlow brandGlowStrong;

  /// 沉浸态指示（全屏 / 投屏连接中）。
  final BrandGlow brandGlowPulse;

  // ---- 编排级动效（DESIGN.md §6 豁免条款：单序列 ≤2.4s，reduceMotion 直跳终态）----
  /// 400ms：遮罩翻词单拍（旧词滑出 + 新词滑入同步完成）。
  final Duration fxWordFlip;

  /// 1500ms：翻词循环模式的停留时长。
  final Duration fxWordHold;

  /// 「减少动效」开关生效时把 [duration] 压成 [Duration.zero]（§4.5）。
  ///
  /// 只压时长、不改结构：调用方仍然走同一条动画代码路径，不靠删代码实现。
  static Duration reduceMotionOf(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

  /// 无障碍「减少动效」是否开启（需要在真/假上分支时用）。
  static bool reduceMotionEnabled(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// 供 `AppTokens.lerp` 使用。
  ///
  /// 度量与亮度无关（深浅两套取值相同），所以这里只做离散切换：插值间距会
  /// 产出刻度外的中间值（如 2.6 px），§4.5 明确禁止。
  AppMetrics lerpFrom(AppMetrics other, double t) => t < 0.5 ? this : other;
}
