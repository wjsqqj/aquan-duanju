import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

/// 指数阻尼追踪器（effect-atlas 移植 · E0 基建）。
///
/// 输入只改 [target]；值每帧按 `a += (b-a)·(1-exp(-rate·dt))` 向目标收敛，
/// **帧率无关**（比例只取决于 rate 与真实步长）。物理循环对齐
/// `jelly_surface.dart` 的既有惯例：
/// - 固定 1/120s 步长、单帧最多补 4 步（卡顿跳帧防护，多余时间丢弃，
///   不会一步吃掉整个 gap）；
/// - gap 与速度都小于 [epsilon] 判 settled → 自动停 Ticker（静止零开销）；
/// - [target] setter 在差值超阈值时自动重启 Ticker。
///
/// `reduceMotion` 不在本类门控（kit 不读 MediaQuery）：消费方在
/// `AppMetrics.reduceMotionEnabled(context)` 时直接调 [jumpTo] 落终态。
class FxDamper {
  FxDamper({
    required TickerProvider vsync,
    this.rate = 8,
    this.epsilon = 0.01,
  }) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// 收敛速率：每秒吃掉剩余 gap 的比例系数（越大追得越急）。
  final double rate;

  /// 收敛判定阈值：gap 与速度都小于它才算 settled。
  final double epsilon;

  double _value = 0;
  double _target = 0;
  double _velocity = 0;
  Duration _last = Duration.zero;

  /// 单物理步长 1/120s（8333µs，与 jelly_surface 同值）。
  static const int _stepMicros = 8333;
  static const double _stepSeconds = 1 / 120;

  /// 单步吃掉 gap 的比例：1-exp(-rate·h)，帧率无关的收敛比例。
  late final double _stepConsume = 1 - math.exp(-rate * _stepSeconds);

  /// 当前值。
  double get value => _value;

  /// 追踪目标。
  double get target => _target;

  /// 速度（指数逼近的解析导数 dv/dt = rate·gap），用于 settled 判定。
  double get velocity => _velocity;

  /// 是否已收敛（gap 与速度都小于 [epsilon]）。
  bool get isSettled =>
      (_target - _value).abs() < epsilon && _velocity.abs() < epsilon;

  /// 调试/测试口：Ticker 是否在跑（settled 停表后应回落为 false）。
  bool get isTicking => _ticker.isActive;

  set target(double t) {
    if (_target == t) return;
    _target = t;
    // 差值在 epsilon 内不值得起表（isSettled 判定本来就会立刻停）。
    if (!isSettled) _ensureTicker();
  }

  /// 直接落终态：跳过动画把值钉在 [v] 并停表。
  ///
  /// 这是 reduceMotion 的既定出口（只压时长不删代码路径的例外——
  /// 阻尼追踪没有「中间过程」可保留，直跳等价于 0 时长动画）。
  void jumpTo(double v) {
    _value = v;
    _target = v;
    _velocity = 0;
    _stopTicker();
  }

  void _ensureTicker() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _stopTicker() {
    if (!_ticker.isActive) return;
    _ticker.stop();
  }

  void _onTick(Duration elapsed) {
    final Duration dt = _last == Duration.zero
        ? const Duration(microseconds: _stepMicros)
        : elapsed - _last;
    _last = elapsed;
    // 固定 1/120s 步长，最多补 4 步：卡顿后把超出部分丢弃，不让一步
    // 吃掉整个 gap（对齐 jelly_surface.dart:172-177 的跳帧防护）。
    final int steps = (dt.inMicroseconds / _stepMicros).clamp(1, 4).toInt();
    for (var i = 0; i < steps; i++) {
      final double gap = _target - _value;
      if (gap.abs() < epsilon) {
        // 差值进阈值：钉在终值，剩余步数不再消耗。
        _value = _target;
        _velocity = 0;
        break;
      }
      _value += gap * _stepConsume;
      _velocity = (_target - _value) * rate;
    }
    if (isSettled) {
      _value = _target;
      _velocity = 0;
      _stopTicker();
    }
  }

  /// 停表并释放 Ticker；调用后不可再用。
  void dispose() {
    _stopTicker();
    _ticker.dispose();
  }
}
