import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'app_icons.dart';

/// 分区标题：`title` + 可选 `subtitle` + 可选右侧动作 + 可选折叠开关。
///
/// 折叠沿用「最近在读 / 继续观看」那套约定（11-05）：
/// 箭头用 `keyboard_arrow_up/down`，`tooltip` 为「收起<标题>」/「展开<标题>」，
/// `visualDensity: compact` 保证标题行高度不因为按钮而变高。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onToggle,
    this.collapsed = false,
    this.padding,
  });

  /// 分区标题（`h3` 字阶）。
  final String title;

  /// 副标题 / 补充说明（`caption` + 次要色）；`null` 不渲染。
  final String? subtitle;

  /// 右侧动作（「查看全部」文字按钮、计数等）。
  final Widget? trailing;

  /// 折叠开关回调；`null` 表示不显示箭头。
  final VoidCallback? onToggle;

  /// 当前是否已折叠：只影响箭头方向与 tooltip，内容由调用方自己收缩。
  final bool collapsed;

  /// 标题行内边距；`null` 取 `s16 / s12 / s16 / s8`。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final EdgeInsetsGeometry inset = padding ??
        EdgeInsets.fromLTRB(
          tokens.metrics.s16,
          tokens.metrics.s12,
          tokens.metrics.s16,
          tokens.metrics.s8,
        );
    final String? sub = subtitle;
    final Widget? trailingWidget = trailing;
    final VoidCallback? toggle = onToggle;
    return Padding(
      padding: inset,
      child: Row(
        spacing: tokens.metrics.s8,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: tokens.metrics.s2,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.h3,
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.caption
                        .copyWith(color: tokens.colors.textSecondary),
                  ),
              ],
            ),
          ),
          ?trailingWidget,
          if (toggle != null)
            IconButton(
              tooltip: collapsed ? '展开$title' : '收起$title',
              onPressed: toggle,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                collapsed ? AppIcons.expand : AppIcons.collapse,
                size: tokens.metrics.s20,
              ),
            ),
        ],
      ),
    );
  }
}
