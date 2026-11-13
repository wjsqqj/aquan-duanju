import 'package:flutter/material.dart';
import 'package:gooey/gooey.dart';

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
      builder: (context, child) {
        final double t = _t.value;
        // gooey 卫星滴（批次⑤「Toast 分裂」消费点，AC21）：
        // 出现时一颗 brand 色小滴从主体外吸附融合进来（间距 32→0），
        // 融合过程中 gooey 膜把两团拉出连接组织，滴本体随后溶解
        // （尺寸 10→0）。主主体仍走 easeOutBack 缩放。
        final double gap = (1 - t) * 32;
        final double dot = (1 - t) * 10;
        return Transform.scale(
          scale: 0.82 + 0.18 * t,
          alignment: Alignment.centerLeft,
          child: GooeyZone(
            gooiness: 26,
            color: const Color(0x8FFF7A45),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: gap,
              children: [
                GooeyBlob(child: child!),
                GooeyBlob(
                  child: SizedBox.square(
                    dimension: dot.clamp(0.0, 10.0),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
