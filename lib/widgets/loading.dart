import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'ui/avatar_walk_loading.dart' show GroundDashes;

/// 全站统一的加载动画：**走路的小人**（用户头像 + 颠步 + 地面虚线滚动 + 光扫）。
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
    final double dashShift = _t * 90 % 26;
    final double avatarH = widget.size * 1.25;
    final double sweep =
        _reduceMotion ? -0.3 : ((_t % 2.4) / 2.4) * 1.6 - 0.3;
    final Color groundColor = widget.color ??
        (dark ? Colors.white.withValues(alpha: 0.55)
              : Colors.black.withValues(alpha: 0.45));

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
          // 头像（颠步 + 倾斜 + 光扫）
          Positioned(
            bottom: widget.size * 0.12 + bob,
            child: Transform.rotate(
              angle: tilt * math.pi / 180,
              child: ShaderMask(
                blendMode: BlendMode.srcATop,
                shaderCallback: (Rect bounds) {
                  return LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      Colors.transparent,
                      (dark ? Colors.white : Colors.white)
                          .withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                    stops: <double>[
                      (sweep - 0.25).clamp(-1.0, 1.0),
                      sweep.clamp(-1.0, 1.0),
                      (sweep + 0.25).clamp(-1.0, 2.0),
                    ],
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
        ],
      ),
    );
  }
}
