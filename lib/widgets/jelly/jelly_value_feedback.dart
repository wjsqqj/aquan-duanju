import 'package:flutter/material.dart';

import '../../theme/jelly_tokens.dart';
import '../../theme/player_overlay_theme.dart';
import 'jelly_surface.dart';

/// 播放器手势反馈 HUD（批次③ 果冻手势，交接 T3.3）。
///
/// 「实心果冻」暗色凝胶块：音量 / 亮度 / seek 预览值变化时，凝胶被挤一下
/// （melt 档：软、慢、流动感），文字居中浮在果冻上。
///
/// - [value] 变化 → 内部 [JellySurfaceController.squash(0.10)]；
/// - 文字/图标色用 [PlayerOverlayTokens.textPrimary]（OSD 永远在暗底上）；
/// - `reduceMotion` 时 JellySurface 不起 ticker，只剩静态凝胶块（AC20）；
/// - 尺寸固定 200×64：HUD 文案（「音量 100%」「00:12 / 45:30」）都在
///   这个包络内，果冻尺寸稳定才不会拖拽时跳变。
class JellyValueFeedback extends StatefulWidget {
  const JellyValueFeedback({
    super.key,
    required this.text,
    this.icon,
    this.color,
  });

  /// 当前值文案（调用方拼好，如「音量 80%」）。
  final String text;

  /// 可选前导图标（OSD 反馈图标）。
  final IconData? icon;

  /// 凝胶主色；`null` 取暗色墨面（播放器 HUD 档）。
  final Color? color;

  @override
  State<JellyValueFeedback> createState() => _JellyValueFeedbackState();
}

class _JellyValueFeedbackState extends State<JellyValueFeedback> {
  final JellySurfaceController _controller = JellySurfaceController();
  int _lastValueHash = 0;

  @override
  void didUpdateWidget(covariant JellyValueFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文案变化（音量/亮度/时间在拖拽中持续变）→ 挤一下。
    final int hash = Object.hash(widget.text, widget.icon);
    if (hash != _lastValueHash) {
      _lastValueHash = hash;
      _controller.squash(0.10);
    }
  }

  @override
  Widget build(BuildContext context) {
    final JellySurface surface = JellySurface(
      size: const Size(200, 64),
      preset: JellyPreset.melt,
      controller: _controller,
      color: widget.color ?? const Color(0xFF33353A),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(
              widget.icon,
              color: PlayerOverlayTokens.textPrimary,
              size: 22,
            ),
            const SizedBox(width: 8),
          ],
          Text(
            widget.text,
            style: PlayerOverlayTokens.stylePrimaryBody.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    return IgnorePointer(child: Center(child: surface));
  }
}
