import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'app_gap.dart';
import 'stage_blobs.dart';

/// 个性化走路加载页（用户头像 + 程序化走路动画 + 落步压缩 + 光扫）。
///
/// 单张静态抠图实现「走路感」的三件套：
/// 1. **颠步**：头像按步频上下弹跳（|sin|），带轻微左右倾斜——迈步的重心感；
/// 2. **地面虚线左移**：跑步机错觉——脚下虚线向左滚动 = 人在向前走；
/// 3. **影子随跳缩放**：跳起时影子变小变淡、落地变大变实——体积感。
///
/// 外加 **落步果冻压缩**（design §1.1，纯相位公式 O(1)）与 **光扫**：
/// 周期恰为 2 个步频周期（每两次落步一道），半步后跟一道 0.25 白窄副光，
/// 扫向水平分量随步向缓变（ShaderMask 实时遮罩）。
/// 背景叠 ShellStage 同款氛围光斑层（[StageBlobs]），内容 250ms 渐入
/// 柔化「原生橙启动页 → 氛围页」的颜色跳变。
/// reduceMotion：渐入时长归零（直接全量呈现）、全部静止。
class AvatarWalkLoading extends StatefulWidget {
  const AvatarWalkLoading({super.key, this.tip = '加载中…'});

  final String tip;

  @override
  State<AvatarWalkLoading> createState() => _AvatarWalkLoadingState();
}

class _AvatarWalkLoadingState extends State<AvatarWalkLoading>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _t = 0;

  // 内容渐入（250ms = panel 档）：柔化原生橙启动页 → 氛围页的颜色跳变；
  // 时长经 reduceMotionOf 归零时直接置满值——零时长 controller 也要等
  // 一帧 ticker 才完成，置 1 才是「reduceMotion 立即全量呈现」。
  late final AnimationController _fadeIn = AnimationController(vsync: this);
  bool _fadeInStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!MediaQuery.disableAnimationsOf(context)) _ticker.start();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fadeIn.duration = AppMetrics.reduceMotionOf(
      context,
      context.app.metrics.panel,
    );
    if (!_fadeInStarted) {
      _fadeInStarted = true;
      if (_fadeIn.duration == Duration.zero) {
        _fadeIn.value = 1;
      } else {
        _fadeIn.forward();
      }
    }
  }

  void _onTick(Duration elapsed) {
    setState(() => _t = elapsed.inMicroseconds / 1e6);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fadeIn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color ground = dark ? Colors.white24 : Colors.black26;
    final bool disabled = MediaQuery.disableAnimationsOf(context);
    // 走路周期：1.1Hz 步频。
    final double walk = _t * math.pi * 2 * 1.1;
    final double bob = disabled ? 0 : math.sin(walk).abs() * 7;
    final double tilt = disabled ? 0 : math.sin(walk) * 2.5;
    // 落步果冻压缩（design §1.1）：纯相位公式 O(1)，无 SoftRing 无新状态字段；
    // q = cos²(walk)，触地（walk=0/π，bob 触底）达峰 1，两次/步频周期；
    // 页面级全系数；reduceMotion q 恒 0。
    final double q = disabled ? 0 : (1 + math.cos(2 * walk)) / 2;
    final double wobble = math.sin(3 * walk + math.pi / 2) * 0.018 * q;
    final double squashX = 1 + 0.055 * q + wobble;
    final double squashY = 1 - 0.070 * q - wobble;
    // reduceMotion（含运行中切换）：虚线与 bob/tilt/sweep 一并静止（R1.6 全程口径，
    // 质检 P2-4——ticker 未停时 _t 仍前进，dashShift 必须单独门控）。
    final double dashShift = disabled ? 0 : _t * 90 % 26;
    // 光扫对齐步频（design §1.2）：周期 = 恰 2 个步频周期（每两次落步一道光），
    // 行程沿用 -0.3→1.3；扫向水平分量乘 sin(walk)，随步向缓变（非硬 sign）。
    // 双波次：主光（0.65 白）+ 半步后（walk 偏移 π）0.25 白窄副光。
    final double sweep = disabled
        ? -0.3
        : ((walk % (4 * math.pi)) / (4 * math.pi)) * 1.6 - 0.3;
    final double sweep2 = disabled
        ? -0.3
        : ((walk + math.pi) % (4 * math.pi)) / (4 * math.pi) * 1.6 - 0.3;
    final double sweepDir = math.sin(walk);
    // 两道带的停靠点合并排序，保证 LinearGradient stops 单调递增。
    final List<(double, Color)> nodes = <(double, Color)>[
      ((sweep - 0.25).clamp(0.0, 1.0), Colors.transparent),
      (sweep.clamp(0.0, 1.0), Colors.white.withValues(alpha: 0.65)),
      ((sweep + 0.25).clamp(0.0, 1.0), Colors.transparent),
      ((sweep2 - 0.12).clamp(0.0, 1.0), Colors.transparent),
      (sweep2.clamp(0.0, 1.0), Colors.white.withValues(alpha: 0.25)),
      ((sweep2 + 0.12).clamp(0.0, 1.0), Colors.transparent),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    return Scaffold(
      backgroundColor:
          dark ? const Color(0xFF141414) : const Color(0xFFFAF7F5),
      // ShellStage 同构氛围层：背景色之上、内容之下叠光斑
      // （IgnorePointer 不挡交互；dark 与 ground 色同一判定源）。
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(child: StageBlobs(dark: dark)),
          Center(
            child: FadeTransition(
              opacity: _fadeIn,
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
                        // 头像（走路颠步 + 落步果冻压缩 + 光扫）
                        Positioned(
                          bottom: 18 + bob,
                          child: Transform.rotate(
                            angle: tilt * math.pi / 180,
                            // 压缩套在 rotate 内层：轴心 = 头像底缘中心，压扁贴地。
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
                                    colors: <Color>[
                                      for (final (double, Color) n in nodes)
                                        n.$2,
                                    ],
                                    stops: <double>[
                                      for (final (double, Color) n in nodes)
                                        n.$1,
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
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  // 品牌标语：**普通文本**（曾用 FxSmearWordmark 拖影甩入）。
                  // 用户实测：拖影/涂抹的中间帧看着像「被油墨涂黑」的一团，
                  // 观感极差 —— 引导页要的是干净可读的字（2026-11-16）。
                  Text(
                    '阿圈短剧',
                    style: context.app.h3.copyWith(
                      color: context.app.colors.textPrimary,
                    ),
                  ),
                  AppGap.v(AppGapSize.s8),
                  Text(
                    widget.tip,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
  bool shouldRepaint(covariant GroundDashes old) =>
      old.shift != shift || old.color != color;
}
