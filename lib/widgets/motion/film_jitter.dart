import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_curves.dart';

/// 确定性伪随机（effect-atlas 纪律：乱码/沸腾/抖动一律**不用**真随机，
/// 同输入必同输出，回放与测试可复现）。输入两个整数（通道/步号），
/// 输出 [0,1)。纯函数无状态。
///
/// 实现：32 位 murmur 风格位混淆，两次混合消除相邻步号的相关性。
double fxHash01(int a, int b) {
  final int h = _mix32(_mix32(a) ^ _mix32(b));
  return h / 0x100000000;
}

int _mix32(int x) {
  x &= 0xFFFFFFFF;
  x ^= x >> 16;
  x = (x * 0x7FEB352D) & 0xFFFFFFFF;
  x ^= x >> 15;
  x = (x * 0x846CA68B) & 0xFFFFFFFF;
  x ^= x >> 16;
  return x;
}

/// 播放 CTA 胶片抖动（effect-atlas film-jitter-hover 移植 · E4）。
///
/// 桌面 hover 时播放主 CTA 呈现老胶片放映的微抖质感：
/// - **外层**：微倾放大 scale 1.035 + rotate -1°（[AppMetrics.hover] 150ms
///   档 + [Fx.spring] 过冲；atlas hover 档同源）；
/// - **内容层**：三个 [AnimationController] 以互质周期（470/430/390ms——
///   atlas 420/330/520ms 循环的等比微调，保持「三条轨道几乎不重合」的
///   跳帧节奏）驱动 `Fx.stepped(6)` 阶梯值：rotate ±0.4° / dx ±0.5px /
///   dy ±0.3px，每控制器一帧一跳（step-end，零 tween），取值走
///   [fxHash01] 确定性 hash（通道 i × 帧号）；
/// - 离开即复位：外层 Animated* 回位（150ms 隐式过渡），三控制器
///   stop + reset。
///
/// 结构：`MouseRegion > AnimatedScale > AnimatedRotation > AnimatedBuilder
/// > child`——纯视觉增强层，**不包按钮手势**（MouseRegion 不参与手势
/// 竞技场；Transform 不改命中），按钮本体的按压语义原样保留。
///
/// 门控：仅桌面（`Theme.of(context).platform`，contract 沉淀口径）且非
/// reduceMotion 才装 MouseRegion 与控制器；移动/TV/reduceMotion **直接
/// 返回 child**（零开销，渲染与改前逐像素一致）。
class FxFilmJitter extends StatefulWidget {
  const FxFilmJitter({super.key, required this.child});

  /// 播放 CTA（按钮本体或其内容层）。
  final Widget child;

  @override
  State<FxFilmJitter> createState() => _FxFilmJitterState();
}

/// 抖动参数（kit 级常量，atlas film-jitter-hover 出处；E4 design §3）。
abstract final class FxFilmJitterTuning {
  /// 外层微倾放大量（hover 态 scale）。
  static const double hoverScale = 1.035;

  /// 外层微倾角度：-1°（turns 计）。
  static const double hoverTiltTurns = -1 / 360;

  /// 内容层阶梯抖动：rotate ±0.4°。
  static const double jitterRotateDegrees = 0.4;

  /// 度→弧度换算（微角度统一走这里，避免逐处写 pi/180）。
  static const double degreeToRadians = math.pi / 180.0;

  /// 内容层阶梯抖动：水平 ±0.5px。
  static const double jitterDxPx = 0.5;

  /// 内容层阶梯抖动：垂直 ±0.3px。
  static const double jitterDyPx = 0.3;

  /// 阶梯帧数（`Fx.stepped(6)`：6 帧 step-end 跳变）。
  static const int steppedFrames = 6;

  /// 三控制器互质周期（ms）。atlas film-jitter 的 420/330/520ms 循环在
  /// Flutter 侧等比微调为 470/430/390——两两互质，合成图案的最小公倍
  /// 周期最长，肉眼看不出规律。
  static const int periodRotateMs = 470;
  static const int periodDxMs = 430;
  static const int periodDyMs = 390;
}

class _FxFilmJitterState extends State<FxFilmJitter>
    with TickerProviderStateMixin {
  AnimationController? _rotate;
  AnimationController? _dx;
  AnimationController? _dy;
  bool _hovered = false;
  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    // 桌面判定走 Theme.platform（MaterialApp 缺省 = defaultTargetPlatform；
    // 测试可用 ThemeData(platform:) 注入，不动 debug 全局变量）。
    final bool desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    // 门控：桌面 + 非 reduceMotion 才建 MouseRegion/控制器（移动/TV 零开销）。
    if (!desktop || AppMetrics.reduceMotionEnabled(context)) return;
    _rotate = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: FxFilmJitterTuning.periodRotateMs),
    );
    _dx = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: FxFilmJitterTuning.periodDxMs),
    );
    _dy = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: FxFilmJitterTuning.periodDyMs),
    );
  }

  void _onEnter(PointerEnterEvent _) {
    if (_hovered) return;
    setState(() => _hovered = true);
    // repeat() 让 value 在 0..1 按各自 duration 循环——阶梯曲线取帧号。
    _rotate?.repeat();
    _dx?.repeat();
    _dy?.repeat();
  }

  /// 离开即复位：外层 Animated* 回位（150ms 隐式），内容层停表归零。
  void _onExit(PointerExitEvent _) {
    if (!_hovered) return;
    setState(() => _hovered = false);
    for (final AnimationController? c in <AnimationController?>[
      _rotate,
      _dx,
      _dy,
    ]) {
      c?.stop();
      c?.reset();
    }
  }

  /// 当前帧的阶梯抖动值（三通道相位由互质周期天然错开）。
  ///
  /// 非 hover（静置/离开复位后）恒为 0——控制器 reset 落在 0 帧，但
  /// 确定性 hash 的 0 帧取值并非 0，必须显式归零才能「离开即复位」
  /// （静置态与改前渲染逐像素一致）。
  (double, double, double) get _jitter {
    if (!_hovered) return (0, 0, 0);
    return (
      (fxHash01(1, _frame(_rotate)) * 2 - 1) *
          FxFilmJitterTuning.jitterRotateDegrees,
      (fxHash01(2, _frame(_dx)) * 2 - 1) * FxFilmJitterTuning.jitterDxPx,
      (fxHash01(3, _frame(_dy)) * 2 - 1) * FxFilmJitterTuning.jitterDyPx,
    );
  }

  /// 控制器当前所处的阶梯帧号（0..5，step-end：帧内恒定）。
  int _frame(AnimationController? c) {
    if (c == null) return 0;
    final double step = Fx.stepped(FxFilmJitterTuning.steppedFrames)
        .transform(c.value);
    return (step * FxFilmJitterTuning.steppedFrames).round().clamp(
      0,
      FxFilmJitterTuning.steppedFrames - 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_rotate == null) return widget.child;
    final AppMetrics m = context.app.metrics;
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: AnimatedScale(
        scale: _hovered ? FxFilmJitterTuning.hoverScale : 1.0,
        duration: m.hover,
        curve: Fx.spring,
        child: AnimatedRotation(
          turns: _hovered ? FxFilmJitterTuning.hoverTiltTurns : 0.0,
          duration: m.hover,
          curve: Fx.spring,
          child: AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[_rotate!, _dx!, _dy!]),
            builder: (context, child) {
              // 静置（未 hover）：直通 child，不挂变换层（复位即逐像素一致）。
              if (!_hovered) return child!;
              final (double rot, double dx, double dy) = _jitter;
              return Transform.translate(
                offset: Offset(dx, dy),
                child: Transform.rotate(
                  angle: rot * FxFilmJitterTuning.degreeToRadians,
                  alignment: Alignment.center,
                  child: child,
                ),
              );
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _rotate?.dispose();
    _dx?.dispose();
    _dy?.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/film_jitter_test.dart）----

  @visibleForTesting
  bool get debugAnimated => _rotate != null;

  @visibleForTesting
  bool get debugHovered => _hovered;

  @visibleForTesting
  bool get debugJittering => _rotate?.isAnimating == true;

  @visibleForTesting
  (double, double, double) get debugJitter => _jitter;
}
