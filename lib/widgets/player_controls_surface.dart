import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/widgets.dart';

import '../theme/player_overlay_theme.dart';

/// 播放器控制栏的视觉外壳：整屏压暗 scrim + 控件内容。
///
/// **契约：空白处只画不挡。**
///
/// 控制栏与「视频手势层」在播放页的 `Stack` 里是**兄弟**，控制栏在上；
/// `Stack` 的命中测试遇到第一个命中的孩子就停。所以控制栏里任何铺满全屏
/// 又吸收命中的节点，都会让下层的 `_onSurfaceTap` 彻底收不到点击 ——
/// 用户看到「单击收不起控制栏」，以及更要命的「双击全屏 / 双击暂停失效」
/// （第一次点击呼出控制栏，第二次点击正好落在这些节点上）。
///
/// 两个已踩过的坑，改动时别再踩回去：
/// - `Container(color:)` / 裸 `ColoredBox` 的 render object 是 opaque 命中，
///   必须包 [IgnorePointer]；
/// - [MouseRegion] 默认 `opaque: true` 也会铺满全屏吸收命中，必须显式
///   `opaque: false`（仍然收 hover 事件，控制栏续期不受影响）。
///
/// 只有控件内容（按钮、进度条）自己吸收命中，这就是 ExoPlayer / YouTube
/// 的经典分层。
class PlayerControlsSurface extends StatelessWidget {
  const PlayerControlsSurface({super.key, required this.child, this.onHover});

  /// 鼠标在控制栏区域移动（用来顺延自动隐藏计时）。
  final void Function(PointerHoverEvent event)? onHover;

  /// 控件内容（顶栏 / 底栏）。空白区域应保持命中透明。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const IgnorePointer(
          child: ColoredBox(color: PlayerOverlayTokens.scrimSoft),
        ),
        MouseRegion(
          // 默认 opaque 会吃掉下层点击，显式关掉（hover 照收）。
          opaque: false,
          onHover: onHover,
          child: child,
        ),
      ],
    );
  }
}
