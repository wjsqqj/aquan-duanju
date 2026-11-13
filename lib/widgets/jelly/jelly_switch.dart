import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'jelly_press.dart';

/// 果冻开关（批次④，implement.md 1c.8）：凝胶轨道 + 弹簧压扁的滑块。
///
/// - 轨道：开 = 品牌色实心果冻、关 = `surface2`，`micro` 时长过渡；
/// - 滑块：白球被「捏」着走——切换瞬间 [JellyPress] 触发一次挤压回弹
///   （k=460/c=8 手感档），`reduceMotion` 时不起弹簧、只做位移；
/// - 手感参数复用 [JellyPress] 的被测默认值（k=460/c=8），不另开一套。
///
/// 不是 `Switch` 的替代品：无 Material 焦点环语义，只用于设置行的视觉层；
/// 焦点与无障碍由外层行组件（`_SettingsSwitchTile` 等）负责。
class JellySwitch extends StatefulWidget {
  const JellySwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<JellySwitch> createState() => _JellySwitchState();
}

class _JellySwitchState extends State<JellySwitch> {
  final JellyPressController _controller = JellyPressController();

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final bool enabled = widget.onChanged != null;
    final Color track = widget.value
        ? tokens.colors.brand
        : tokens.colors.surface2;
    final Color thumb = tokens.colors.textPrimary;

    final Widget knob = JellyPress(
      controller: _controller,
      strength: 0.10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: thumb,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: m.s4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: SizedBox.square(dimension: m.s20),
      ),
    );

    return Semantics(
      button: true,
      toggled: widget.value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                _controller.kick(0.08);
                widget.onChanged!(!widget.value);
              }
            : null,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: AnimatedContainer(
            duration: AppMetrics.reduceMotionOf(context, m.micro),
            curve: m.microCurve,
            width: m.s48,
            height: m.s24 + m.s4,
            padding: EdgeInsets.all(m.s4 - 1),
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.all(Radius.circular(m.radiusPill)),
              border: Border.all(
                color: tokens.colors.hairline,
                width: m.hairline,
              ),
            ),
            child: AnimatedAlign(
              duration: AppMetrics.reduceMotionOf(context, m.micro),
              curve: m.microCurve,
              alignment:
                  widget.value ? Alignment.centerRight : Alignment.centerLeft,
              child: knob,
            ),
          ),
        ),
      ),
    );
  }
}
