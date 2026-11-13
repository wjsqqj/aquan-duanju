import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 卡片用的「按压果冻」：弹簧驱动的非等比缩放 + 轻微倾斜。
///
/// ## 手感模型
///
/// 单自由度弹簧-质量-阻尼：`a = (target - x)·k - v·c`（质量恒为 1），
/// 阻尼比 `ζ = c / (2√k)`：
/// - ζ < 1 才有过冲（弹回来再冲过头），ζ 越小弹得越多；
/// - 邦布那种「duang duang」大约 ζ ≈ 0.18–0.22，能看见 2–3 次余摆。
///
/// 默认参数（k=460, c=8）→ ζ ≈ 0.187。按下时刚度/阻尼同时放大 2.4×，
/// 让「成形」很快、不那么晃；松手才交给软阻尼慢慢 duang。
///
/// ## 为什么卡片不用软体轮廓
///
/// 卡片尺寸大、形变小，18 点样条逼近 radius=12 的圆角会失真，且网格里
/// 几百张卡每张都要裁剪不划算。形状真正被软体驱动的是按钮/blob
/// （见 `JellySurface`）。
class JellyPress extends StatefulWidget {
  const JellyPress({
    super.key,
    required this.child,
    this.strength = 0.085,
    this.spring = 460,
    this.damping = 8,
    this.tilt = 2.2,
    this.enabled = true,
    this.controller,
  });

  final Widget child;

  /// 按下时的最大压缩比（0.085 ≈ 宽 +8.5%、高 -8.5%）。
  final double strength;

  /// 弹簧刚度 k：越大回弹越快。
  final double spring;

  /// 阻尼系数 c（**不是** 0~1 的比值）：越小越弹。
  /// `ζ = c / (2√k)`，默认 8 / (2√460) ≈ 0.187。
  final double damping;

  /// 最大倾斜角度（度）：按下时轻微歪一下，动画才有"重量"。
  final double tilt;

  final bool enabled;

  /// 外部控制句柄；挂载时登记、销毁时注销。
  final JellyPressController? controller;

  @override
  State<JellyPress> createState() => _JellyPressState();
}

/// `JellyPress` 的外部控制句柄：消费方（如 [JellySwitch]）在值变化时触发
/// 一次挤压脉冲，不必重建 widget。
class JellyPressController {
  _JellyPressState? _state;

  /// 踢一个初始压缩量，弹簧自由收敛回 0。
  void kick(double initialSquash) => _state?._kickPress(initialSquash);
}

class _JellyPressState extends State<JellyPress>
    with SingleTickerProviderStateMixin {
  /// 按下阶段刚度放大倍数：进得快、少晃。
  static const double _pressStiffnessScale = 2.4;
  static const double _pressDampingScale = 2.2;

  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// 当前压缩量（正=压扁，负=鼓胀）。
  double _squash = 0;
  double _velocity = 0;
  bool _pressed = false;
  bool _ticking = false;

  /// 外部脉冲入口（[JellyPressController] 用）。
  void _kickPress(double initialSquash) {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _squash = initialSquash;
    _velocity = 0;
    _start();
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.controller?._state = this;
  }

  double get _target => _pressed ? widget.strength : 0.0;

  double get _k =>
      _pressed ? widget.spring * _pressStiffnessScale : widget.spring;

  double get _c =>
      _pressed ? widget.damping * _pressDampingScale : widget.damping;

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // 半隐式欧拉；步长钳在 1/240~1/120，避免大帧差时炸开
    final h = dt.clamp(1 / 240, 1 / 120);
    final accel = (_target - _squash) * _k - _velocity * _c;
    _velocity += accel * h;
    _squash += _velocity * h;

    if ((_squash - _target).abs() < 0.0003 && _velocity.abs() < 0.003) {
      _squash = _target;
      _velocity = 0;
      _stop();
    }
    if (mounted) setState(() {});
  }

  void _start() {
    if (_ticking) return;
    _last = Duration.zero;
    _ticker.start();
    _ticking = true;
  }

  void _stop() {
    if (!_ticking) return;
    _ticker.stop();
    _ticking = false;
  }

  void _setPressed(bool value) {
    if (!mounted) return;
    setState(() => _pressed = value);
    _start();
  }

  @override
  void dispose() {
    widget.controller?._state = null;
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final double ratio = widget.strength == 0
        ? 0
        : (_squash / widget.strength).clamp(-1.0, 1.0);
    final double angle = ratio * widget.tilt * math.pi / 180;

    return Listener(
      // 用 Listener 而不是 GestureDetector：不参与手势竞技场，
      // 不会和卡片的 InkWell / 拖拽抢手势。
      // `translucent`：子级（Card/InkWell）继续收事件，本层也能感知；
      // 默认的 deferToChild 在子级为空或透明时收不到任何指针事件。
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!widget.enabled || reduceMotion) return;
        _setPressed(true);
      },
      onPointerUp: (_) {
        if (!widget.enabled || reduceMotion) return;
        _setPressed(false);
      },
      onPointerCancel: (_) {
        if (!widget.enabled || reduceMotion) return;
        _setPressed(false);
      },
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..rotateZ(angle)
          ..scaleByDouble(1 + _squash, 1 - _squash, 1.0, 1.0),
        child: widget.child,
      ),
    );
  }
}
