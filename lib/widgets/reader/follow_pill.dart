import 'package:flutter/material.dart';

/// 「继续跟随」药丸：用户手动翻页把自动跟随挂起后，给他一个**一键抢回**的入口。
///
/// 样式沿用工程既有的胶囊浮层（`player_screen` 的静音提示 `_buildMutedHint`）：
/// 右下角 `Positioned` + 半透明黑胶囊 + 一个动作文字按钮。它不占用 SnackBar，
/// 也不改变顶/底栏显隐；点击只做一件事 —— 告诉页面「恢复跟随」，
/// 朗读本身从头到尾没被暂停过。
class FollowPill extends StatelessWidget {
  const FollowPill({
    super.key,
    required this.onTap,
    this.right = 20,
    this.bottom = 72,
  });

  /// 点「继续跟随」：页面清挂起并立刻补一次跟随。
  final VoidCallback onTap;

  /// 浮层位置：右下角，默认让开底部工具栏。
  final double right;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: right,
      bottom: bottom,
      child: Material(
        color: Colors.black.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.my_location, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text(
                '朗读已停在这里',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              TextButton(
                onPressed: onTap,
                child: const Text(
                  '继续跟随',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 精度徽标：`真人音轨·段` / `智能朗读·段` / `云合成·词`。
///
/// 文案由 `ReaderSpeechController.speechBadgeOf(activePath, highlightGranularity)`
/// 算好传进来 —— 这个 widget 不再自己判断精度，免得再长出第二套真值。
class SpeechBadge extends StatelessWidget {
  const SpeechBadge({super.key, required this.text, this.foreground});

  /// 空串表示当前没有朗读会话，不画徽标。
  final String text;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final color = foreground ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
