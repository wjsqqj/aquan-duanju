import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../jelly/jelly_switch.dart';

/// 开关设置行（批次④/⑤ 共享位型）：图标 + 标题/说明 + [JellySwitch]。
///
/// 旧 `SwitchListTile` 的全站替换位——语义保持（value/onChanged 原样透传，
/// `secondary` → `icon`），视觉收敛到统一行高与果冻手感。
/// 无障碍由 [JellySwitch] 内部 Semantics（toggled）上报。
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.secondary,
    this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  /// 行首图标（旧 SwitchListTile 的 `secondary` 位）。
  final Widget? secondary;

  /// 主标题（Text）；`null` 不渲染。
  final Widget? title;

  /// 说明（Text）；`null` 不渲染。
  final Widget? subtitle;

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.s16, m.s4, m.s16, m.s4),
      child: Row(
        spacing: m.s12,
        children: [
          ?secondary,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: m.s2,
              children: [
                if (title != null)
                  DefaultTextStyle.merge(
                    style: tokens.body,
                    child: title!,
                  ),
                if (subtitle != null)
                  DefaultTextStyle.merge(
                    style: tokens.caption
                        .copyWith(color: tokens.colors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    child: subtitle!,
                  ),
              ],
            ),
          ),
          JellySwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
