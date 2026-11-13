import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';

/// Toast 的果冻形变层（批次④，implement.md 1c.8）。
///
/// 与 ①b 的玻璃 Toast 共存的分工：**玻璃做底、果冻做形变**——外壳折射由
/// `showGlassToast` 的 [AppGlass] 负责，本组件只负责内容出现时的
/// 「duang」：缩放从 0.82 弹到 1（软弹簧曲线），带一点过冲。
///
/// `reduceMotion` 开启时直接静止呈现（AC20）。SnackBar 的 dismiss 动画
/// 不归本组件管（框架自带）。
class JellyToastMorph extends StatefulWidget {
  const JellyToastMorph({super.key, required this.child});

  final Widget child;

  @override
  State<JellyToastMorph> createState() => _JellyToastMorphState();
}

class _JellyToastMorphState extends State<JellyToastMorph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    // 软弹簧：一次过冲、快速收住（melt 档的观感，不抢玻璃外壳的戏）。
    curve: Curves.easeOutBack,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      builder: (context, child) => Transform.scale(
        scale: 0.82 + 0.18 * _t.value,
        alignment: Alignment.centerLeft,
        child: child,
      ),
      child: widget.child,
    );
  }
}
