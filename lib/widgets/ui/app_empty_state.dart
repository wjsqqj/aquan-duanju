import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

/// 统一空态：图标 + 主文案 + 说明 + 可选操作。
///
/// 全站 14 处手写空态收敛到这一个实现（批次⑤），因此这里只留 4 个字段：
/// 图标、标题、说明、动作。空态永远垂直居中，上下各留 `s24`——
/// 之前各屏的留白从 8 到 40 不等，列表很短时「空」和「还在加载」分不开。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    this.description,
    this.action,
    this.icon,
  });

  /// 主文案（`title` 字阶）。这句话要回答「这里为什么是空的」。
  final String title;

  /// 说明（`caption` + 次要色），补充「怎么让它不空」。
  final String? description;

  /// 可选操作（重试 / 去发现 / 添加源）。
  final Widget? action;

  /// 可选图标；`null` 时不渲染图标。
  final IconData? icon;

  /// 图标边长：56（= `s48 + s8`），沿用旧空态尺寸。
  static const double _iconSize = 56;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final String? descriptionText = description;
    final Widget? actionWidget = action;
    final IconData? iconData = icon;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.metrics.s24,
          vertical: tokens.metrics.s24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: tokens.metrics.s8,
          children: <Widget>[
            if (iconData != null)
              Icon(iconData, size: _iconSize, color: tokens.colors.textTertiary),
            Text(title, textAlign: TextAlign.center, style: tokens.title),
            if (descriptionText != null)
              Text(
                descriptionText,
                textAlign: TextAlign.center,
                style: tokens.caption
                    .copyWith(color: tokens.colors.textSecondary),
              ),
            ?actionWidget,
          ],
        ),
      ),
    );
  }
}
