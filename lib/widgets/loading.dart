import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'ui/avatar_walk_loading.dart' show GroundDashes;

/// 全站统一的加载动画：**走路的小人**（用户头像 + 颠步 + 落步果冻压缩 + 地面虚线
/// 滚动 + 光扫；光扫周期恰为 2 个步频周期，每两次落步一道）。
///
/// 替换原转圈（用户要求「所有转圈圈的加载动画都换成新的加载动画」）。
/// 两种规格 API 不变，调用方无需改动：
/// - 默认构造：页面级（size 32 → 头像高 40，占地约 74×56）；
/// - [AppLoading.inline]：行内级（size 20 → 头像高 25，占地约 46×35）。
///
/// `color` 语义变化：不再是转圈颜色，而是地面线/虚线颜色（深色视频上下文传
/// `Colors.white`）。
///
/// 组件本身不居中，页面级请自行包一层 [Center]。
/// reduceMotion：全部静止（AC20 延续）。
class AppLoading extends StatefulWidget {
  /// 页面级加载（头像高 40）。
  const AppLoading({super.key, this.color})
      : size = 32,
        strokeWidth = 3;

  /// 行内加载（头像高 25）。
  const AppLoading.inline({super.key, this.color})
      : size = 20,
        strokeWidth = 2;

  /// 语义保留：原转圈直径，现作为整体缩放基准。
  final double size;
  final double strokeWidth;

  /// 地面线/虚线颜色（深色视频上下文传 `Colors.white`）。
  final Color? color;

  @override
  State<AppLoading> createState() => _AppLoadingState();
}

class _AppLoadingState extends State<AppLoading>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _t = 0;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    if (mounted) setState(() => _t = elapsed.inMicroseconds / 1e6);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final double walk = _t * math.pi * 2 * 1.1;
    final double bob =
        _reduceMotion ? 0 : math.sin(walk).abs() * widget.size * 0.22;
    final double tilt = _reduceMotion ? 0 : math.sin(walk) * 2.5;
    // 落步果冻压缩（design §1.1）：步频二次谐波纯相位公式，O(1) 无状态无 GC
    //（不用 SoftRing——列表内成片实例化背不动 Verlet）；q = cos²(walk)，
    // 触地（walk=0/π，bob 触底）达峰 1，两次/步频周期；行内级系数减半
    //（像素太少时余摆会糊）；reduceMotion q 恒 0（复用现有分支）。
    final double squashK = widget.size <= 20 ? 0.5 : 1.0;
    final double q = _reduceMotion ? 0 : (1 + math.cos(2 * walk)) / 2;
    final double wobble =
        math.sin(3 * walk + math.pi / 2) * 0.018 * squashK * q;
    final double squashX = 1 + 0.055 * squashK * q + wobble;
    final double squashY = 1 - 0.070 * squashK * q - wobble;
    final double dashShift = _t * 90 % 26;
    final double avatarH = widget.size * 1.25;
    // 光扫对齐步频（design §1.2）：周期 = 恰 2 个步频周期（每两次落步一道光），
    // 行程沿用 -0.3→1.3；扫向水平分量乘 sin(walk)，随步向缓变（非硬 sign）。
    final double sweep = _reduceMotion
        ? -0.3
        : ((walk % (4 * math.pi)) / (4 * math.pi)) * 1.6 - 0.3;
    final double sweepDir = math.sin(walk);
    // 页面级双波次：半步后（walk 偏移 π）一道 0.25 白窄副光；行内级只有主光。
    final bool pageLevel = widget.size > 20;
    final double sweep2 = pageLevel
        ? ((walk + math.pi) % (4 * math.pi)) / (4 * math.pi) * 1.6 - 0.3
        : -0.3;
    final Color groundColor = widget.color ??
        (dark ? Colors.white.withValues(alpha: 0.55)
              : Colors.black.withValues(alpha: 0.45));
    // 主光 + 副光两道带的停靠点合并排序，保证 LinearGradient stops 单调递增。
    final Color hi =
        (dark ? Colors.white : Colors.white).withValues(alpha: 0.6);
    final List<Color> sweepColors;
    final List<double> sweepStops;
    if (pageLevel) {
      final List<(double, Color)> nodes = <(double, Color)>[
        ((sweep - 0.25).clamp(-1.0, 1.0), Colors.transparent),
        (sweep.clamp(-1.0, 1.0), hi),
        ((sweep + 0.25).clamp(-1.0, 2.0), Colors.transparent),
        ((sweep2 - 0.12).clamp(-1.0, 1.0), Colors.transparent),
        (sweep2.clamp(-1.0, 1.0), Colors.white.withValues(alpha: 0.25)),
        ((sweep2 + 0.12).clamp(-1.0, 2.0), Colors.transparent),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      sweepColors = <Color>[for (final (double, Color) n in nodes) n.$2];
      sweepStops = <double>[for (final (double, Color) n in nodes) n.$1];
    } else {
      sweepColors = <Color>[Colors.transparent, hi, Colors.transparent];
      sweepStops = <double>[
        (sweep - 0.25).clamp(-1.0, 1.0),
        sweep.clamp(-1.0, 1.0),
        (sweep + 0.25).clamp(-1.0, 2.0),
      ];
    }

    return SizedBox(
      width: widget.size * 2.3,
      height: widget.size * 1.75,
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: <Widget>[
          // 地面线
          Positioned(
            left: 0,
            right: 0,
            bottom: widget.size * 0.10,
            child: Container(height: 1, color: groundColor),
          ),
          // 地面虚线（左移 = 前进错觉）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: CustomPaint(
              size: Size(widget.size * 2.3, widget.size * 0.14),
              painter: GroundDashes(
                shift: dashShift,
                color: groundColor,
              ),
            ),
          ),
          // 影子（跳起变小变淡）
          Positioned(
            bottom: widget.size * 0.02,
            child: Container(
              width: avatarH * 0.5 - bob * 1.2,
              height: widget.size * 0.10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    (dark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.22 - bob * 0.008),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // 头像（颠步 + 倾斜 + 落步果冻压缩 + 光扫）
          Positioned(
            bottom: widget.size * 0.12 + bob,
            child: Transform.rotate(
              angle: tilt * math.pi / 180,
              // 压缩套在 rotate 内层：轴心 = 头像底缘中心，压扁贴地更真实。
              child: Transform.scale(
                scaleX: squashX,
                scaleY: squashY,
                alignment: Alignment.bottomCenter,
                child: ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (Rect bounds) {
                    return LinearGradient(
                      begin: Alignment(-sweepDir, -1),
                      end: Alignment(sweepDir, 1),
                      colors: sweepColors,
                      stops: sweepStops,
                    ).createShader(bounds);
                  },
                  child: Image.asset(
                    'assets/avatar/avatar.png',
                    height: avatarH,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
