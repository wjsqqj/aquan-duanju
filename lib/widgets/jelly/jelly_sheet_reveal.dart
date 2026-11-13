import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';

/// 玻璃面板的「凝胶展开」入场（批次③ 果冻手势，交接 T3.3）。
///
/// 包一层内容：首帧从「下移 18dp + 压扁 4%」弹性展开到正位——果冻被从
/// 底部托起来的感觉。给 ③ 的选集 / 倍速 / 清晰度玻璃面板用（showGlassSheet
/// 的默认弹出是纯位移曲线，没有果冻的回弹）。
///
/// `reduceMotion` 开启时不动画，直接静止呈现（AC20）。
class JellySheetReveal extends StatefulWidget {
  const JellySheetReveal({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 520),
  });

  final Widget child;
  final Duration duration;

  @override
  State<JellySheetReveal> createState() => _JellySheetRevealState();
}

class _JellySheetRevealState extends State<JellySheetReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    // elasticOut 太闹；0.55 的周期系数给「duang 两下收住」。
    curve: const ElasticOutCurve(0.55),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // reduceMotion 要查 MediaQuery（继承组件），initState 里不能读，挪到这里。
    if (_started) return;
    _started = true;
    if (AppMetrics.reduceMotionEnabled(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) {
        final double v = _t.value;
        return Transform.translate(
          offset: Offset(0, 18 * (1 - v)),
          child: Transform.scale(
            scale: 0.96 + 0.04 * v,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
