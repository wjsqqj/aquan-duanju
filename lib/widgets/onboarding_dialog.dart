import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/tv/tv_mode.dart';
import '../theme/app_metrics.dart';
import '../theme/player_overlay_theme.dart';
import 'tv_scope.dart';
import 'ui/app_gap.dart';

/// 首启新手引导（A5）：首次启动覆盖在首页上的四页卡片。
///
/// 卡片结构与配色基因复用 `player_guide_dialog.dart`（kaixinguo 四步教程卡），
/// 内容取材遵循同一原则——**只教应用自己不会说话的隐性交互**（快捷键 /
/// 右键 / 双击 / 边缘抽屉 / 长按），一眼能懂的入口不教。
/// 内容按 [TvScope] 桌面 / 移动分流；TV 形态不弹（触发处拦截）。
///
/// 只负责「讲」：是否写「已看过」标记由调用方决定（完成与跳过等效），
/// 这样设置页的「重看新手引导」可以复用同一套内容。
Future<void> showOnboardingGuide(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '新手引导',
    barrierColor: const Color(0x9E000000),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => const OnboardingDialog(),
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
    icon: Icons.search_rounded,
    title: 'Ctrl+F / Ctrl+K 随时搜剧',
    body: '任意页面按下即唤起搜索，输入时实时联想剧名。',
  ),
  _GuideStep(
    icon: Icons.favorite_rounded,
    title: '右键卡片收藏追剧',
    body:
        '在剧集卡片上点右键即可追剧 / 想看 / 已看；'
        '收藏的剧在「我的 › 我的追剧」。',
  ),
  _GuideStep(
    icon: Icons.fullscreen_rounded,
    title: '双击进出全屏影院',
    body:
        '播放时双击画面进入 / 退出全屏；全屏下鼠标靠到最右边缘，'
        '选集自动出现。',
  ),
  _GuideStep(
    icon: Icons.speed_rounded,
    title: '长按 2 倍速，D 键开关弹幕',
    body: '按住画面即 2 倍速，按住时向下滑可锁定；按 D 键随时开关弹幕。',
  ),
];

const List<_GuideStep> _mobileSteps = <_GuideStep>[
  _GuideStep(
    icon: Icons.search_rounded,
    title: '搜索有联想和热搜',
    body: '输入剧名时边输边联想；没想法就先看看热搜词。',
  ),
  _GuideStep(
    icon: Icons.favorite_rounded,
    title: '长按海报收藏追剧',
    body: '长按剧集海报即可追剧 / 想看 / 已看；「我的 › 我的追剧」随时接着看。',
  ),
  _GuideStep(
    icon: Icons.swap_vert_rounded,
    title: '上下滑切集，双击暂停',
    body: '沉浸播放里上滑下一集、下滑上一集；双击暂停 / 继续。',
  ),
  _GuideStep(
    icon: Icons.speed_rounded,
    title: '长按 2 倍速，弹幕随手开关',
    body: '按住画面即 2 倍速，按住时向下滑可锁定；控制栏弹幕按钮随时开关。',
  ),
];

class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({super.key});

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 桌面形态讲鼠标 / 键盘交互，其余（手机 / 平板）讲触屏手势。
  /// TV 不弹本引导（触发处拦截），无入口可达 TV 分支。
  List<_GuideStep> get _steps =>
      TvScope.formFactorOf(context) == AppFormFactor.desktop
      ? _desktopSteps
      : _mobileSteps;

  bool get _last => _index >= _steps.length - 1;

  void _go(int page) {
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() {
    if (_last) {
      Navigator.of(context).pop();
      return;
    }
    _go(_index + 1);
  }

  void _prev() {
    if (_index <= 0) return;
    _go(_index - 1);
  }

  @override
  Widget build(BuildContext context) {
    final List<_GuideStep> steps = _steps;
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
                  // PageView 需要有界高度：内容区固定高、四页同尺寸，
                  // 滑动切换时卡片不会跳变；页内居中吸收文案长短差。
                  SizedBox(
                    height: 200,
                    child: PageView(
                      controller: _controller,
                      onPageChanged: (page) => setState(() => _index = page),
                      children: <Widget>[
                        for (final _GuideStep step in steps)
                          Center(
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
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  AppGap.v(AppGapSize.s12),
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
                        child: Text(_last ? '开始使用' : '下一步'),
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
