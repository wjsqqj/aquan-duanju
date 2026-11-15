import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'stage_blobs.dart';

/// 外壳舞台背景（11-14 外壳流体玻璃化 Phase 1，「舞台级」视觉强度）。
///
/// **强碰撞**方向：暗色底 + 大面积品牌色光斑缓慢漂移——所有玻璃面
/// （Rail / 顶栏 / 浮层）透出的不再是死板纯色，而是有颜色变化的舞台。
///
/// 光斑层实现提取为公开 [StageBlobs]（stage_blobs.dart）：启动页
/// AvatarWalkLoading 复用同一氛围层，本组件行为零变化。
class ShellStage extends StatelessWidget {
  const ShellStage({super.key, required this.child});

  /// 页面内容（悬浮其上，不参与光斑动画）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.colors.canvas),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(child: StageBlobs(dark: dark)),
          child,
        ],
      ),
    );
  }
}
