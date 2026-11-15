import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';

/// 舞台氛围光斑层（11-14 外壳流体玻璃化 Phase 1，原 ShellStage 私有层，
/// B4 提取公开供启动页 AvatarWalkLoading 复用同一空气感）。
///
/// - 4 团光斑（brand×2 / info / 反色互补）以 20~34s 不同周期缓慢漂移，
///   形成「灯下液体」的底噪；`reduceMotion` 时静止（AC20 延续）；
/// - 挂载淡入：自首个有效帧起 ~1.2s easeOutCubic 显影（E8 冷启动取证：早期
///   帧暗斑块显影抛光）；`reduceMotion` 静态渲染不走 ramp、直接全量绘制
///   （防静态帧钉在 alpha 0 的永久隐身事故）；
/// - 光斑模糊 80：只作用于背景层，不构成玻璃祖先（§11.5 第 1 条）；
/// - 深浅两套：深色发光更艳（碰撞感主要在深色），浅色降饱和防刺眼。
class StageBlobs extends StatefulWidget {
  const StageBlobs({super.key, required this.dark});

  /// 深浅主题判定（与 ShellStage 同源：`Theme.of(context).brightness`），
  /// 决定光斑 alpha 走哪套档位。
  final bool dark;

  @override
  State<StageBlobs> createState() => _StageBlobsState();
}

class _StageBlobsState extends State<StageBlobs>
    with SingleTickerProviderStateMixin {
  /// 挂载淡入时长（E8 冷启动取证：早期帧暗斑块显影抛光——blob 初始相位在
  /// 引导→首页早期帧呈暗色斑块+梯度 banding、数秒后自愈；淡入自首帧
  /// alpha≈0 起 easeOutCubic 平滑显影，遮住自愈窗口）。
  static const Duration _fadeIn = Duration(milliseconds: 1200);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26),
  );

  bool _started = false;

  /// reduceMotion 分支标记：ticker 不起跑、静态渲染。淡入 ramp 靠已有
  /// ticker 的 elapsed 派生，静态帧没有 elapsed——必须绕过 ramp 直接全量
  /// 绘制，否则 ramp 会把静态帧钉在 alpha 0（永久隐身事故）。
  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMetrics.reduceMotionEnabled(context)) {
      _reducedMotion = true;
      _controller.value = 0.3;
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final Color brand = tokens.colors.brand;
    final Color info = tokens.colors.info;
    // 深色发光更艳（碰撞感主战场）；浅色降饱和防刺眼。
    final double k = widget.dark ? 1.0 : 0.55;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final double t = _controller.value;
        // 挂载淡入 ramp：取已有 ticker 的 elapsed 派生（纯相位公式惯例，
        // 无新 Timer/Controller）。lastElapsedDuration 在 26s repeat 换相时
        // 持续累计（ticker 不重启就不清零），ramp 单调走到 1；phase 上限用
        // 三元钉 1（Curves 变换断言 t∈[0,1]，超 1.2s 后直接钉满）。reduceMotion
        // 静态分支（ticker 不起跑、elapsed 恒空）绕过 ramp 直接全量——防
        // 静态帧钉 0 隐身。
        final int elapsedUs =
            _controller.lastElapsedDuration?.inMicroseconds ?? 0;
        final double phase = elapsedUs >= _fadeIn.inMicroseconds
            ? 1.0
            : elapsedUs / _fadeIn.inMicroseconds;
        final double fade = _reducedMotion
            ? 1.0
            : Curves.easeOutCubic.transform(phase);
        return ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 左上：brand 主光斑，斜向漂移
              _blob(
                brand.withValues(alpha: (widget.dark ? 0.22 : 0.10) * k * fade),
                Offset(-0.05 + 0.06 * t, -0.08 + 0.10 * t),
                0.46,
              ),
              // 右中：info 冷色对撞（碰撞感的另一极）
              _blob(
                info.withValues(alpha: (widget.dark ? 0.16 : 0.08) * k * fade),
                Offset(1.02 - 0.05 * t, 0.32 + 0.08 * t),
                0.40,
              ),
              // 底部：brand 副光斑反向漂移
              _blob(
                Colors.white.withValues(
                  alpha: (widget.dark ? 0.10 : 0.16) * k * fade,
                ),
                Offset(0.30 - 0.10 * t, 1.05 - 0.06 * t),
                0.42,
              ),
              // 右上角小暖斑：打破对称
              _blob(
                brand.withValues(alpha: (widget.dark ? 0.12 : 0.06) * k * fade),
                Offset(0.92 + 0.04 * t, -0.04 + 0.05 * t),
                0.30,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 中心在 [center]（Alignment 语义）、半径为短边 [radiusFactor] 倍的径向光斑。
  Widget _blob(Color color, Offset center, double radiusFactor) {
    return Align(
      alignment: Alignment(center.dx * 2 - 1, center.dy * 2 - 1),
      child: Container(
        width: radiusFactor * 1100,
        height: radiusFactor * 1100,
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
