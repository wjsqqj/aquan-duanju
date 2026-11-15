import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'fx_damp.dart';

/// 速度 → squash 软膝映射（atlas horizontal-wheel-strip 规格）。
///
/// `0.08·(1-exp(-|v|/3600))`：无硬帽的软膝——低速几乎不动（3600px/s 处
/// ≈0.051），极速渐近 0.08。
double fxSquashForVelocity(double velocity) =>
    _kSquashMax * (1 - math.exp(-velocity.abs() / _kVelocityScale));

/// squash 上限（8% 缩量）。
const double _kSquashMax = 0.08;

/// 软膝速度尺度（px/s）：atlas wheel-squash 的指数分母。
const double _kVelocityScale = 3600;

/// 速度 EMA 新值权重（atlas 规格 0.6）。
const double _kVelocityEmaAlpha = 0.6;

/// 海报 rail 的速度 squash 域（effect-atlas wheel-squash 移植 · E1）。
///
/// 包在横向滚动视口（海报 rail 的 ListView / HorizontalScrollStrip）外，
/// 以共享 [ValueNotifier] 广播滚动速度派生的 squash 值；域内的卡包
/// [FxSquashCard] 做等比整体缩（transform-only，无布局动画、无视差）。
///
/// 「减少动效」/ [enabled]=false（TV 形态）→ 整域停用，卡片原样直出；
/// 已在缩时立即归 1（不留残影）。
class FxSquashScope extends StatefulWidget {
  const FxSquashScope({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// false = 整域停用（TV 形态由调用方传 `!TvScope.isTvOf(context)`）。
  final bool enabled;

  @override
  State<FxSquashScope> createState() => _FxSquashScopeState();
}

/// 域数据：notifier 身份稳定（squash 值变化不重建卡片，靠
/// ValueListenableBuilder 自行跟进）；只有 [enabled] 翻转（reduceMotion/
/// TV 形态运行时切换）才重建卡片，让它们摘下/挂上 Transform——若恒
/// false，false→true 后已构建的卡片会一直拿不到 squash。
class _SquashScopeData extends InheritedWidget {
  const _SquashScopeData({
    required this.squash,
    required this.enabled,
    required super.child,
  });

  final ValueListenable<double> squash;
  final bool enabled;

  static _SquashScopeData? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SquashScopeData>();

  @override
  bool updateShouldNotify(_SquashScopeData oldWidget) =>
      oldWidget.enabled != enabled;
}

class _FxSquashScopeState extends State<FxSquashScope>
    with SingleTickerProviderStateMixin {
  /// squash 现值（0..0.08），域内 FxSquashCard 共享监听。
  final ValueNotifier<double> _squash = ValueNotifier<double>(0);

  FxDamper? _damper;
  DateTime? _lastScrollAt;
  double _emaVelocity = 0;
  bool _motionAllowed = false;
  Timer? _idleTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed = widget.enabled && !AppMetrics.reduceMotionEnabled(context);
    if (!_motionAllowed) {
      _idleTimer?.cancel();
      _damper?.jumpTo(0);
      _squash.value = 0;
      _emaVelocity = 0;
      _lastScrollAt = null;
      return;
    }
    _damper ??= FxDamper(
      vsync: this,
      // 拖尾时间常数 τ = fxSquashFollow：rate = 1000ms / 220ms ≈ 4.55。
      rate: 1000 / context.app.metrics.fxSquashFollow.inMilliseconds,
      // squash 值域 0..0.08，默认 epsilon 0.01 占满值 12.5%（可见跳变），
      // 收紧到 0.0005（≈0.6% 缩量内视为停稳）。
      epsilon: 0.0005,
      // 阻尼每帧推进 → 广播给卡片。
      onUpdate: (double value) => _squash.value = value,
    );
  }

  bool _onNotification(ScrollNotification notification) {
    if (!_motionAllowed) return false;
    if (notification is ScrollUpdateNotification) {
      _sampleVelocity(notification.scrollDelta);
    }
    // 注意：ScrollEndNotification **不是**停稳信号——滚轮滑行是逐帧
    // jumpTo，每次 jumpTo 都派发完整的 start/update/end 三元组（end 的
    // dragDetails 为 null），真实结束（拖拽松手/惯性收尾）的 details 也
    // 可能为 null，无法区分。统一改用 fxSquashFollow 空闲窗：超过一窗
    // 没有滚动更新就归零拖尾（[_armIdleTimer]）。
    return false;
  }

  /// 采样滚动速度：delta/dt → EMA（α=0.6）→ squash 目标（软膝映射）。
  void _sampleVelocity(double? delta) {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastScrollAt;
    if (delta != null && delta != 0 && last != null) {
      final double dt = now.difference(last).inMicroseconds / 1e6;
      if (dt > 0) {
        _emaVelocity += _kVelocityEmaAlpha * (delta.abs() / dt - _emaVelocity);
      }
    }
    _lastScrollAt = now;
    _armIdleTimer();
    _damper?.target = fxSquashForVelocity(_emaVelocity);
  }

  /// 空闲窗（一窗无滚动更新 → 停稳归 1）。窗长取 fxSquashFollow：与拖尾
  /// 同源，「停下来再过一拍」就是视觉上的停稳。
  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(
      AppMetrics.reduceMotionOf(context, context.app.metrics.fxSquashFollow),
      _settle,
    );
  }

  void _settle() {
    _emaVelocity = 0;
    _lastScrollAt = null;
    _damper?.target = 0;
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _damper?.dispose();
    _squash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: _SquashScopeData(
        squash: _squash,
        enabled: _motionAllowed,
        child: widget.child,
      ),
    );
  }
}

/// rail 内单卡的速度 squash：共享 notifier → Transform.scale 等比整体缩
/// （alignment center，scale = 1 - squash）。无 [FxSquashScope] 祖先时
/// 原样直出。
class FxSquashCard extends StatelessWidget {
  const FxSquashCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _SquashScopeData? data = _SquashScopeData.maybeOf(context);
    if (data == null || !data.enabled) return child;
    // squash=0 时也保持 Transform：卸下/挂上会造成卡片子树重挂载
    // （runtimeType 变化），静止态 RenderTransform 是恒等变换零开销。
    return ValueListenableBuilder<double>(
      valueListenable: data.squash,
      child: child,
      builder: (context, squash, child) =>
          Transform.scale(scale: 1 - squash, child: child),
    );
  }
}
