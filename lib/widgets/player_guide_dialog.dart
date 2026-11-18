import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_metrics.dart';
import '../theme/player_overlay_theme.dart';
import 'ui/app_gap.dart';

/// 播放器首次使用指南。
///
/// 结构参考 `kaixinguo/view_tutorial.go` 的四步卡片，但内容按本仓两端手势写：
/// 桌面讲全屏/滚轮/快捷键/右侧选集，移动端讲双击暂停/上下滑切集/长按倍速/选集。
///
/// 只负责「讲」：是否暂停播放、是否写「已看过」标记都由调用方决定，
/// 这样设置页也能直接复用同一套内容。
Future<void> showPlayerGuide(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '播放器指南',
    barrierColor: const Color(0x9E000000),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => const _PlayerGuideDialog(),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _GuideStep {
  const _GuideStep({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

const List<_GuideStep> _desktopSteps = <_GuideStep>[
  _GuideStep(
    icon: Icons.fullscreen_rounded,
    title: '双击画面切换全屏',
    body: '双击视频进入 / 退出全屏，F 键同效；Esc 退出全屏。',
  ),
  _GuideStep(
    icon: Icons.volume_up_rounded,
    title: '滚轮调音量，键盘快进快退',
    body: '在画面上滚滚轮调整音量；← / → 快退快进 10 秒，空格暂停 / 继续。',
  ),
  _GuideStep(
    icon: Icons.speed_rounded,
    title: '长按画面 2 倍速',
    body: '按住画面即 2 倍速，松手恢复；按住时向下滑可锁定 2 倍速，'
        '锁定后按住向上滑即可取消。',
  ),
  _GuideStep(
    icon: Icons.format_list_numbered_rounded,
    title: '全屏时鼠标靠右边缘选集',
    body: '全屏下把鼠标移到最右侧边缘，选集面板自动出现；'
        '离开后自动收起。也可以点工具栏「选集」或按 E。',
  ),
];

const List<_GuideStep> _mobileSteps = <_GuideStep>[
  _GuideStep(
    icon: Icons.touch_app_rounded,
    title: '双击暂停 / 继续',
    body: '单击画面显示或隐藏控制栏，双击暂停 / 继续播放。',
  ),
  _GuideStep(
    icon: Icons.swap_vert_rounded,
    title: '上滑下一集，下滑上一集',
    body: '在画面上向上滑切到下一集，向下滑回到上一集；左右拖动仍是快进 / 快退。',
  ),
  _GuideStep(
    icon: Icons.speed_rounded,
    title: '长按画面 2 倍速',
    body: '按住画面即 2 倍速，松手恢复；按住时向下滑可锁定 2 倍速，'
        '锁定后按住向上滑即可取消。',
  ),
  _GuideStep(
    icon: Icons.format_list_numbered_rounded,
    title: '底部「选集」随时换集',
    body: '点控制栏的选集按钮挑集；已看完的集右下角有对勾，选中即从该集开头播放。',
  ),
];

class _PlayerGuideDialog extends StatefulWidget {
  const _PlayerGuideDialog();

  @override
  State<_PlayerGuideDialog> createState() => _PlayerGuideDialogState();
}

class _PlayerGuideDialogState extends State<_PlayerGuideDialog> {
  int _index = 0;

  bool get _desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  List<_GuideStep> get _steps => _desktop ? _desktopSteps : _mobileSteps;

  bool get _last => _index >= _steps.length - 1;

  void _next() {
    if (_last) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index++);
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
  }

  @override
  Widget build(BuildContext context) {
    final List<_GuideStep> steps = _steps;
    final _GuideStep step = steps[_index];
    final TextTheme textTheme = Theme.of(context).textTheme;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Center(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: 420,
              constraints: const BoxConstraints(maxWidth: 420),
              margin: EdgeInsets.only(
                left: AppSpacing.s20,
                right: AppSpacing.s20,
              ),
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              decoration: BoxDecoration(
                color: PlayerOverlayTokens.panelFill,
                borderRadius: BorderRadius.all(
                  Radius.circular(PlayerOverlayTokens.radiusPanel),
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 32,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    step.icon,
                    size: 40,
                    color: PlayerOverlayTokens.accent,
                  ),
                  AppGap.v(AppGapSize.s16),
                  Text(
                    step.title,
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(
                      color: PlayerOverlayTokens.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  AppGap.v(AppGapSize.s8),
                  Text(
                    step.body,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: PlayerOverlayTokens.textSecondary,
                      height: 1.55,
                    ),
                  ),
                  AppGap.v(AppGapSize.s20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: AppSpacing.s4,
                    children: <Widget>[
                      for (int i = 0; i < steps.length; i++)
                        Container(
                          width: i == _index ? 18 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i == _index
                                ? PlayerOverlayTokens.accent
                                : PlayerOverlayTokens.textTertiary,
                            borderRadius: const BorderRadius.all(
                              Radius.circular(3),
                            ),
                          ),
                        ),
                    ],
                  ),
                  AppGap.v(AppGapSize.s12),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text(
                          '跳过',
                          style: PlayerOverlayTokens.styleTertiary,
                        ),
                      ),
                      const Spacer(),
                      if (_index > 0)
                        TextButton(
                          onPressed: _prev,
                          child: const Text(
                            '上一步',
                            style: PlayerOverlayTokens.styleSecondary,
                          ),
                        ),
                      AppGap.h(AppGapSize.s4),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: PlayerOverlayTokens.accent,
                          foregroundColor: PlayerOverlayTokens.panelFill,
                        ),
                        onPressed: _next,
                        child: Text(_last ? '开始观看' : '下一步'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
