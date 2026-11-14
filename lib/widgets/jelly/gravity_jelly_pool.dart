import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gooey/gooey.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';

/// 重力果冻池（11-14 外壳流体玻璃化 Phase 3，「舞台级」强度）。
///
/// N 颗果冻滴在容器内受重力下落、底部弹跳（恢复系数 0.55）、gooey 膜融合拉丝。
/// 扰动源（tab 切换 / 点击）给滴一个向上冲量——「根据重力弹」的本体。
///
/// - 物理：显式欧拉（半隐式），滴间不碰撞（融合观感由 gooey 膜承担）；
/// - 渲染：GooeyZone + GooeyBlob（gooiness 45 舞台级），滴体 brand 高饱和 + 白高光点；
/// - D15：0 个 SoftRing（gooey 渲染 + 自管粒子），预算安全；
/// - reduceMotion：滴静止沉底，不动画（AC20 延续）；
/// - 「果冻抖动」：滴落地时触发 [onImpact]，宿主可借此给容器一次性 squash。
class GravityJellyPool extends StatefulWidget {
  const GravityJellyPool({
    super.key,
    this.dropCount = 5,
    this.gooiness = 45,
    this.onImpact,
  });

  /// 外部扰动句柄：`GlobalKey<GravityJellyPoolState>` + [GravityJellyPoolState.kick]。


  /// 滴数（舞台级 5 颗）。
  final int dropCount;

  /// gooey 融合强度（45 = 拉丝拉满）。
  final double gooiness;

  /// 任一滴砸到底面时回调（幅度 0~1，用于宿主果冻抖动）。
  final ValueChanged<double>? onImpact;

  @override
  State<GravityJellyPool> createState() => GravityJellyPoolState();
}

class GravityJellyPoolState extends State<GravityJellyPool>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  late List<_Drop> _drops;
  Size _size = Size.zero;
  final math.Random _rand = math.Random();
  bool _reduceMotion = false;

  static const double _gravity = 980;
  static const double _restitution = 0.62;
  static const double _maxSpeed = 1400;

  @override
  void initState() {
    super.initState();
    _drops = <_Drop>[];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = AppMetrics.reduceMotionEnabled(context);
  }

  void _seedDrops(Size size) {
    _size = size;
    const radii = <double>[9, 13, 6, 11, 5, 8];
    // 滴半径随池高缩放：Rail（~1000 高）满尺寸、顶栏（56 高）缩到合身。
    final double scale = (size.height / 220).clamp(0.45, 1.0);
    _drops = <_Drop>[
      for (var i = 0; i < widget.dropCount; i++)
        _Drop(
          radius: radii[i % radii.length] * scale,
          x: size.width * (0.15 + 0.7 * _rand.nextDouble()),
          y: size.height * _rand.nextDouble() * 0.5,
          vx: (_rand.nextDouble() - 0.5) * 120,
          vy: 0,
        ),
    ];
  }

  /// 外部扰动：给最靠近 [anchorDx] 的滴一个向上冲量。
  void kick({required double anchorDx, double impulse = 520}) {
    if (_reduceMotion || _drops.isEmpty) return;
    _Drop best = _drops.first;
    double bestD = double.infinity;
    for (final _Drop d in _drops) {
      final double dist = (d.x - anchorDx).abs();
      if (dist < bestD) {
        bestD = dist;
        best = d;
      }
    }
    best.vy -= impulse + _rand.nextDouble() * 140;
    best.vx += (_rand.nextDouble() - 0.5) * 160;
    if (!_ticker.isActive) _ticker.start();
  }

  /// 水平扰动（顶栏液柱用）：给所有滴一个横向冲量（滚动速度驱动）。
  void kickH(double impulse) {
    if (_reduceMotion || _drops.isEmpty) return;
    for (final _Drop d in _drops) {
      d.vx += impulse;
    }
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration elapsed) {
    if (_size == Size.zero) return;
    final double dt = 1 / 60;
    double maxImpact = 0;
    for (final _Drop d in _drops) {
      d.vy += _gravity * dt;
      // 风阻
      d.vx *= 0.995;
      d.vy = d.vy.clamp(-_maxSpeed, _maxSpeed);
      d.x += d.vx * dt;
      d.y += d.vy * dt;
      // 侧壁
      if (d.x < d.radius) {
        d.x = d.radius;
        d.vx = -d.vx * _restitution;
      } else if (d.x > _size.width - d.radius) {
        d.x = _size.width - d.radius;
        d.vx = -d.vx * _restitution;
      }
      // 地面
      final double floor = _size.height - d.radius - 4;
      if (d.y > floor) {
        d.y = floor;
        if (d.vy > 0) {
          final double hit = d.vy / _maxSpeed;
          d.vy = -d.vy * _restitution;
          if (hit > maxImpact) maxImpact = hit;
          // 横向摩擦
          d.vx *= 0.9;
        }
        // 极低速时贴地休眠
        if (d.vy.abs() < 24) d.vy = 0;
      }
      if (d.y < d.radius) {
        d.y = d.radius;
        d.vy = -d.vy * _restitution;
      }
    }
    if (maxImpact > 0.08) widget.onImpact?.call(maxImpact.clamp(0.0, 1.0));
    // 全部休眠且无扰动 → 停 ticker（静止不排帧）
    final bool allAsleep = _drops.every((d) => d.vy == 0 && d.vx.abs() < 1);
    if (allAsleep) _ticker.stop();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final Color base = tokens.colors.brand;
    return LayoutBuilder(builder: (context, constraints) {
      final Size cs = Size(constraints.maxWidth, constraints.maxHeight);
      if (_size == Size.zero) {
        // 首帧：按容器尺寸播种（滴半径随池高缩放——Rail 满尺寸、顶栏缩 0.45）。
        _size = cs;
        _seedDrops(cs);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_reduceMotion && !_ticker.isActive) _ticker.start();
        });
      } else if ((cs.width - _size.width).abs() > _size.width * 0.3 ||
          (cs.height - _size.height).abs() > _size.height * 0.3) {
        // 窗口 resize → 液体重新泼溅（滴回到上半区重新落下）。
        _size = cs;
        _seedDrops(cs);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_reduceMotion && !_ticker.isActive) _ticker.start();
        });
      }
      return ClipRect(
        child: GooeyZone(
          gooiness: 50,
          color: base.withValues(alpha: 0.30),
          child: Stack(
            children: <Widget>[
              for (final _Drop d in _drops)
                Positioned(
                  left: d.x - d.radius,
                  top: d.y - d.radius,
                  child: GooeyBlob(
                    child: Container(
                      width: d.radius * 2,
                      height: d.radius * 2,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: <Color>[
                            Colors.white.withValues(alpha: 0.55),
                            base.withValues(alpha: 0.85),
                            Color.lerp(base, Colors.black, 0.25)!,
                          ],
                          stops: const <double>[0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _Drop {
  _Drop({
    required this.radius,
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
  });

  final double radius;
  double x;
  double y;
  double vx;
  double vy;
}



/// 滚动 → 顶栏液体扰动的广播（home 的 NotificationListener 发，
/// 各 GlassAppBar 里的液柱池收）。值为 (方向 ±1, 冲量 0~60)。
class LiquidBus {
  LiquidBus._();

  static final ValueNotifier<(double, double)> impulse = ValueNotifier((0, 0));

  static void fire(double direction, double magnitude) {
    impulse.value = (direction, magnitude);
  }
}
