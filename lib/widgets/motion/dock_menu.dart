import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../theme/player_overlay_theme.dart';
import 'fx_curves.dart';
import 'fx_stagger.dart';

/// 行条目的交错槽距（atlas dock-menu-dropdown 规格）。
///
/// kit 级常量（atlas 出处；挂 [AppMetrics.fxDockOpen] 的编排豁免序列内，
/// 不另占五档）。
const Duration fxDockRowStagger = Duration(milliseconds: 50);

/// 面板最小宽（与 PopupMenuButton 的默认 min width 同值，回显文本短的
/// 菜单不至于窄成一条）。
const double _kPanelMinWidth = 112;

/// dock 菜单项（值 + 标签）。
class FxDockMenuItem<T> {
  const FxDockMenuItem({required this.value, required this.label});

  final T value;
  final String label;
}

/// 播放器 dock 菜单（effect-atlas dock-menu-dropdown 移植 · E2）。
///
/// 触发钮点开后面板**向下 + 向宽**伸展（topLeft 锚点，[Fx.dockIn] 强
/// in-out 开合），行条目按 [fxDockRowStagger] 交错浮现；指向行被色板从
/// **指针进入边**刷满（origin 只在刷板 settled 时切换，动画中不翻边）。
/// **开慢关快**：开 [AppMetrics.fxDockOpen]（540ms）、关
/// [AppMetrics.fxDockClose]（360ms）——关时全体一起退，不做行独立退场
/// （atlas 规格）。
///
/// 实体面板（播放器红线内）：[PlayerOverlayTokens.panelFill] 底 +
/// `stylePrimary` 文字，纯 Container/Transform/Opacity——**零玻璃、零
/// BackdropFilter、零 shader**。行板取 `colors.surface3`，选中行文字取
/// `colors.brand`。
///
/// 弹层机制：[OverlayPortal] + `CompositedTransformTarget/Follower`（本
/// 代码库无既有 overlay 惯例，取 SDK 的现代口：卸载自动摘除，无需手工
/// 管理 OverlayEntry 生命周期）。外点关闭走全屏不透明手势屏障（透明
/// ModalBarrier 语义）；Esc 走面板 autofocus + [CallbackShortcuts]——
/// 与 PopupMenuButton 的「点外/Esc 关闭」语义对齐。
///
/// 选中回显：触发钮标签由调用方用 [value] 重建（与现 PopupMenuItem
/// initialValue 语义一致，本组件不替调用方排版触发钮）。
///
/// 门控：TV 形态由**调用方**分流回 PopupMenuButton（焦点导航优先）；
/// reduceMotion 时 open/close 时长归零——无交错直开直关。
class FxDockMenu<T> extends StatefulWidget {
  const FxDockMenu({
    super.key,
    required this.items,
    required this.value,
    required this.onSelected,
    required this.child,
    this.onOpenChanged,
  });

  final List<FxDockMenuItem<T>> items;

  /// 当前选中值（行高亮；触发钮文案由调用方重建）。
  final T? value;

  final ValueChanged<T> onSelected;

  /// 触发钮 visuals（点它开菜单；开着时点它落在屏障上=关闭）。
  final Widget child;

  /// 开合状态回调：true = 面板已弹出，false = 已完全收起。
  ///
  /// 播放器用它暂停「控件条 4 秒自动隐藏」——控制栏是条件挂载的，
  /// 一旦置 false 连 OverlayPortal 一起卸载，菜单会凭空消失。
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<FxDockMenu<T>> createState() => _FxDockMenuState<T>();
}

class _FxDockMenuState<T> extends State<FxDockMenu<T>>
    with TickerProviderStateMixin {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController(
    debugLabel: 'FxDockMenu',
  );

  late AnimationController _open;
  late AnimationController _close;
  bool _closing = false;
  bool _wired = false;

  /// 面板向上弹出（贴底的控制栏放不下向下的面板）。
  ///
  /// 播放器底栏就在窗口底边：面板固定向下弹时整块落在窗口外，用户点了
  /// 倍速/清晰度「什么都没发生」（用户实测）。开合时按触发钮的全局位置
  /// 与可用高度自动翻向。
  bool _opensUp = false;

  /// 面板高度估算（行高 + 内边距）：只用于判断向上还是向下，允许保守。
  double get _estimatedPanelHeight =>
      widget.items.length * PlayerOverlayTokens.targetLg +
      PlayerOverlayTokens.radiusPanel;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    final AppMetrics m = context.app.metrics;
    // reduceMotion：时长归零 → forward/reverse 直跳终态（无交错直开直关）。
    _open = AnimationController(
      vsync: this,
      duration: AppMetrics.reduceMotionOf(context, m.fxDockOpen),
    );
    _close = AnimationController(
      vsync: this,
      duration: AppMetrics.reduceMotionOf(context, m.fxDockClose),
    );
    _close.addStatusListener(_onCloseStatus);
  }

  void _onCloseStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _portal.hide();
      _closing = false;
      _open.value = 0;
      _close.value = 0;
    });
    widget.onOpenChanged?.call(false);
  }

  bool get _shown => _portal.isShowing;

  void _show() {
    if (_shown || _closing) return;
    setState(() {
      _opensUp = _shouldOpenUp();
      _portal.show();
      _closing = false;
      _open.forward(from: 0);
    });
    widget.onOpenChanged?.call(true);
  }

  /// 下方放不下面板、上方更宽裕时向上弹（贴底控制栏必走这条路）。
  bool _shouldOpenUp() {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final Offset origin = box.localToGlobal(Offset.zero);
    final double screenHeight = MediaQuery.sizeOf(context).height;
    final double below = screenHeight - (origin.dy + box.size.height);
    return below < _estimatedPanelHeight && origin.dy > below;
  }

  void _dismiss() {
    if (!_shown || _closing) return;
    setState(() {
      _closing = true;
      _close.forward(from: 0);
    });
  }

  void _select(T value) {
    widget.onSelected(value);
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildOverlayChild,
      child: CompositedTransformTarget(
        link: _link,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _show,
          child: widget.child,
        ),
      ),
    );
  }

  Widget _buildOverlayChild(BuildContext context) {
    final AppMetrics m = context.app.metrics;
    return Stack(
      children: [
        // 外点关闭屏障（不透明吃掉全部指针，含触发钮——再点即关）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          // 向上弹时以触发钮顶边为基准，让面板底边贴上去。
          targetAnchor: _opensUp ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: _opensUp ? Alignment.bottomLeft : Alignment.topLeft,
          showWhenUnlinked: false,
          offset: Offset(0, _opensUp ? -m.s8 : m.s8),
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
            },
            child: Focus(
              autofocus: true,
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[_open, _close]),
                builder: (context, _) => _buildPanel(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPanel(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final double openT = _open.value;
    final double closeT = _close.value;
    // 有效几何进度：开 = openT；关 = 1 - closeT（全体一起退，topLeft 收回）。
    final double geo = _closing ? 1.0 - closeT : openT;
    if (geo <= 0) return const SizedBox.shrink();
    final double factor = Fx.dockIn.transform(geo);
    return ClipRect(
      child: Align(
        // 展开方向跟随弹出方向：向下弹从顶边铺开，向上弹从底边长起来。
        alignment: _opensUp ? Alignment.bottomLeft : Alignment.topLeft,
        widthFactor: factor,
        heightFactor: factor,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            constraints: const BoxConstraints(minWidth: _kPanelMinWidth),
            decoration: BoxDecoration(
              color: PlayerOverlayTokens.panelFill,
              borderRadius: BorderRadius.all(
                Radius.circular(PlayerOverlayTokens.radiusPanel),
              ),
            ),
            padding: EdgeInsets.fromLTRB(m.s8, m.s8, m.s8, m.s8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  _buildRow(context, i),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单行：交错浮现（开）/一齐淡出（关）+ hover 进入边刷板。
  Widget _buildRow(BuildContext context, int index) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final double openT = _open.value;
    final double closeT = _close.value;
    final double rowT = _closing
        ? 1.0 - closeT
        : Fx.glide.transform(
            staggeredInterval(
              index,
              base: Duration.zero,
              unit: fxDockRowStagger,
              total: m.fxDockOpen,
            ).transform(openT),
          );
    final FxDockMenuItem<T> item = widget.items[index];
    final bool selected = widget.value != null && widget.value == item.value;
    return Opacity(
      opacity: rowT.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - rowT) * m.s8),
        child: _DockRow(
          label: item.label,
          selected: selected,
          onTap: () => _select(item.value),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // 面板被外部卸载（例如控制栏随 _showControls 收起）时也要复位调用方的
    // 「菜单打开中」标记，否则自动隐藏会被一个已不存在的菜单永久挂住。
    if (_shown) widget.onOpenChanged?.call(false);
    _close.removeStatusListener(_onCloseStatus);
    _close.dispose();
    _open.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/dock_menu_test.dart）----

  @visibleForTesting
  bool get debugShown => _shown;

  @visibleForTesting
  bool get debugClosing => _closing;

  @visibleForTesting
  bool get debugOpensUp => _opensUp;

  @visibleForTesting
  double get debugOpenT => _open.value;

  @visibleForTesting
  Duration? get debugOpenDuration => _open.duration;

  @visibleForTesting
  Duration? get debugCloseDuration => _close.duration;
}

/// 菜单行：hover 时色板从指针进入边刷满（origin 只在 settled 时切换）。
class _DockRow extends StatefulWidget {
  const _DockRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DockRow> createState() => _DockRowState();
}

class _DockRowState extends State<_DockRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill;

  /// 刷板起点：true = 从行顶边起、false = 从行底边起。
  bool _fromTop = true;

  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    _fill = AnimationController(
      vsync: this,
      // 刷板用 panel 档（250ms）；reduceMotion 归零直刷满。
      duration: AppMetrics.reduceMotionOf(context, context.app.metrics.panel),
    );
  }

  void _onEnter(PointerEnterEvent event) {
    // origin 随进入边；但刷板动画进行中不翻边（只在 settled 时切换）。
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final bool fromTop = event.localPosition.dy * 2 < box.size.height;
    final bool settled = _fill.value <= 0 || _fill.value >= 1;
    if (settled && fromTop != _fromTop) {
      setState(() => _fromTop = fromTop);
    }
    _fill.forward();
  }

  void _onExit(PointerExitEvent _) => _fill.reverse();

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final TextStyle labelStyle = widget.selected
        ? PlayerOverlayTokens.stylePrimaryBody.copyWith(
            color: tokens.colors.brand,
          )
        : PlayerOverlayTokens.stylePrimaryBody;
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _fill,
          builder: (context, child) {
            final double fillT = _fill.value.clamp(0.0, 1.0);
            return Stack(
              children: [
                if (fillT > 0)
                  Positioned.fill(
                    child: Transform.scale(
                      scaleY: fillT,
                      alignment: _fromTop
                          ? Alignment.topCenter
                          : Alignment.bottomCenter,
                      // 面板底色恒为 [PlayerOverlayTokens.panelFill]，高亮只能
                      // 取同族半透明白；取主题 surface3 在浅色主题是纯白，
                      // 悬停会糊出一块白斑（用户实测「白色块」）。
                      child: const ColoredBox(
                        color: PlayerOverlayTokens.panelHover,
                      ),
                    ),
                  ),
                ?child,
              ],
            );
          },
          child: Container(
            constraints: BoxConstraints(
              minHeight: PlayerOverlayTokens.targetLg,
            ),
            padding: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, m.s8),
            alignment: Alignment.centerLeft,
            child: Text(widget.label, style: labelStyle),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }
}
