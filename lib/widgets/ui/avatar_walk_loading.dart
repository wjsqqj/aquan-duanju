import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 个性化走路加载页（用户头像 + 程序化走路动画 + 光扫）。
///
/// 单张静态抠图实现「走路感」的三件套：
/// 1. **颠步**：头像按步频上下弹跳（|sin|），带轻微左右倾斜——迈步的重心感；
/// 2. **地面虚线左移**：跑步机错觉——脚下虚线向左滚动 = 人在向前走；
/// 3. **影子随跳缩放**：跳起时影子变小变淡、落地变大变实——体积感。
///
/// 外加 **光扫**：每 2.4s 一道斜向高光从头像上扫过（ShaderMask 实时遮罩）。
/// reduceMotion：全部静止。
class AvatarWalkLoading extends StatefulWidget {
  const AvatarWalkLoading({super.key, this.tip = '加载中…'});

  final String tip;

  @override
  State<AvatarWalkLoading> createState() => _AvatarWalkLoadingState();
}

class _AvatarWalkLoadingState extends State<AvatarWalkLoading>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _t = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!MediaQuery.disableAnimationsOf(context)) _ticker.start();
    });
  }

  void _onTick(Duration elapsed) {
    setState(() => _t = elapsed.inMicroseconds / 1e6);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color ground = dark ? Colors.white24 : Colors.black26;
    // 走路周期：1.1Hz 步频。
    final double walk = _t * math.pi * 2 * 1.1;
    final double bob = MediaQuery.disableAnimationsOf(context)
        ? 0
        : math.sin(walk).abs() * 7;
    final double tilt = MediaQuery.disableAnimationsOf(context)
        ? 0
        : math.sin(walk) * 2.5;
    final double dashShift = _t * 90 % 26;
    // 光扫位置：2.4s 一轮，从 -0.3 扫到 1.3。
    final double sweep = ((_t % 2.4) / 2.4) * 1.6 - 0.3;

    return Scaffold(
      backgroundColor:
          dark ? const Color(0xFF141414) : const Color(0xFFFAF7F5),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 280,
              height: 230,
              child: Stack(
                alignment: Alignment.bottomCenter,
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 地面线
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 20,
                    child: Container(height: 1.2, color: ground),
                  ),
                  // 地面虚线（左移 = 走路错觉）
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: CustomPaint(
                      size: const Size(280, 10),
                      painter: GroundDashes(
                        shift: dashShift,
                        color: ground,
                      ),
                    ),
                  ),
                  // 影子（跳起变小变淡）
                  Positioned(
                    bottom: 4,
                    child: Container(
                      width: 92 - bob * 2.4,
                      height: 12 - bob * 0.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: <Color>[
                            (dark ? Colors.black : Colors.black)
                                .withValues(alpha: 0.28 - bob * 0.012),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 头像（走路颠步 + 光扫）
                  Positioned(
                    bottom: 18 + bob,
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
                              Colors.white.withValues(alpha: 0.65),
                              Colors.transparent,
                            ],
                            stops: <double>[
                              (sweep - 0.25).clamp(0.0, 1.0),
                              sweep.clamp(0.0, 1.0),
                              (sweep + 0.25).clamp(0.0, 1.0),
                            ],
                          ).createShader(bounds);
                        },
                        child: Image.asset(
                          'assets/avatar/avatar.png',
                          height: 170,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              widget.tip,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地面虚线画笔：8 段圆头短横线，随 [shift] 左移循环。
/// 地面虚线画笔：8 段圆头短横线，随 [shift] 左移循环（公开供 AppLoading 复用）。
class GroundDashes extends CustomPainter {
  const GroundDashes({required this.shift, required this.color});

  final double shift;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const double gap = 26;
    for (double x = -gap; x < size.width + gap; x += gap) {
      final double dx = x - shift;
      canvas.drawLine(Offset(dx, size.height / 2), Offset(dx + 14, size.height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant GroundDashes old) => old.shift != shift;
}
