import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/app_tokens.dart';
import 'app_glass.dart';

/// 悬浮玻璃顶栏（11-14 外壳流体玻璃化 Phase 2）。
///
/// 与普通 `AppBar` 的区别：**透明玻璃带**——内容（滚动列表）从它下面穿过，
/// BackdropFilter 实时磨砂采样。调用方 Scaffold 需配
/// `extendBodyBehindAppBar: true`，内容顶部加 [height] 的补偿留白。
///
/// 只服务 4 个主 tab 外壳（二级页面沿用普通 AppBar，避免 42 屏回归）。
/// 文字对比度靠玻璃底托（AppGlass 内置 surface3 半透明）保证。
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    required this.title,
    this.actions,
    this.height = 56,
  });

  /// 标题（左对齐，h2 字阶）。
  final String title;

  /// 右侧动作按钮（原 AppBar.actions 语义）。
  final List<Widget>? actions;

  /// 玻璃带高度。
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return AppGlass(
      tier: AppGlassTier.overlay,
      // brand tint 有色玻璃：与 Rail 呼应，视觉碰撞的主色锚点。
      tint: tokens.colors.brand.withValues(alpha: dark ? 0.16 : 0.10),
      radius: 0,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.fromLTRB(m.s16, 0, m.s8, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.app.h2,
                ),
              ),
              ...?actions,
            ],
          ),
        ),
      ),
    );
  }
}
