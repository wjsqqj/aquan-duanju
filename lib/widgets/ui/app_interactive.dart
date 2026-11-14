import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_color.dart';
import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';

/// 四态交互基座：默认 / hover / pressed / focus / disabled（design.md §5.1）。
///
/// 只由 `MouseRegion` + `AnimatedContainer` + `Focus` 组成，不引入任何第三方
/// hover / 动画依赖（D5）。电视形态继续走 `TvFocusable`，本组件不参与遥控器
/// 焦点视觉。
///
/// 状态取值（全部来自 Token）：
/// - 默认：`surface1` 底 + `hairline` 描边；
/// - hover / selected：`surface2` 底 + `brand` @40% 描边；
/// - pressed：再深一档（`surface3`）+ 缩放到 0.985；
/// - focus：描边加粗到 `focusRing`（2px）并用 `focusRing` 色；
/// - disabled：`Opacity(0.5)` + 普通箭头光标。
///
/// `onTap == null`（或 `enabled == false`）时退化为**静态容器**：不进入焦点
/// 遍历、不响应 hover、不显示手型光标。点按 / 焦点都用语义回调而非 `InkWell`，
/// 因为 `InkWell` 的水波纹会盖在封面图上，且无法在 `AnimatedContainer` 里做
/// 描边渐变。
class AppInteractive extends StatefulWidget {
  const AppInteractive({
    super.key,
    required this.child,
    this.onTap,
    this.tooltip,
    this.selected = false,
    this.enabled = true,
    this.focusable = true,
    this.padding,
    this.radius,
    this.cursor,
    this.darkSurface = false,
  });

  final Widget child;

  /// 点按回调。为 `null` 表示这里只有内容、没有交互（静态容器）。
  final VoidCallback? onTap;

  /// 悬停提示；`null` 表示不挂 `Tooltip`。
  final String? tooltip;

  /// 选中态：底色与描边按 hover 档处理，用于「当前 Tab / 当前项」。
  final bool selected;

  /// `false` 时半透明并且不可点。
  final bool enabled;

  /// `false` 时仍可点，但不进入焦点遍历（例如整页拖拽区域）。
  final bool focusable;

  final EdgeInsetsGeometry? padding;

  /// 圆角；`null` 取 `radiusMd`（卡片）。
  final BorderRadius? radius;

  /// 覆盖鼠标光标；`null` 时按可点性自动取 `click` / `basic`。
  final MouseCursor? cursor;

  /// 暗玻璃表面（岩浆灯 Rail 用）：填充从主题的 surface1/2/3 换成
  /// 「白 @5/14/22%」的半透明层——暗底上保持玻璃通透，不再糊出白色实心块。
  final bool darkSurface;

  @override
  State<AppInteractive> createState() => _AppInteractiveState();
}

class _AppInteractiveState extends State<AppInteractive> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  /// 真正可交互：有回调、且没被禁用。
  bool get _interactive => widget.onTap != null && widget.enabled;

  void _setHovered(bool value) {
    if (!_interactive || value == _hovered) return;
    setState(() => _hovered = value);
  }

  void _setPressed(bool value) {
    if (!_interactive || value == _pressed) return;
    setState(() => _pressed = value);
  }

  void _setFocused(bool value) {
    if (!_interactive || value == _focused) return;
    setState(() => _focused = value);
  }

  /// 键盘可达性：桌面端用 Tab 聚焦后，回车 / 空格必须能激活。
  /// 没有这一层，「focus 描边」就只是装饰。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool activate = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space;
    if (!activate) return KeyEventResult.ignored;
    widget.onTap?.call();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppColors colors = tokens.colors;
    final AppMetrics m = tokens.metrics;

    final bool interactive = _interactive;
    final bool hovered = interactive && _hovered;
    final bool pressed = interactive && _pressed;
    final bool focused = interactive && _focused;
    final bool highlighted = hovered || widget.selected;

    final Color fill = widget.darkSurface
        ? Colors.white.withValues(alpha: pressed
            ? 0.22
            : highlighted
                ? 0.14
                : 0.05)
        : pressed
            ? colors.surface3
            : highlighted
                ? colors.surface2
                : colors.surface1;
    final Color stroke = focused
        ? colors.focusRing
        : highlighted
            ? (widget.darkSurface
                ? Colors.white.withValues(alpha: 0.30)
                : colors.brand.withValues(alpha: 0.4))
            : (widget.darkSurface
                ? Colors.white.withValues(alpha: 0.12)
                : colors.hairline);
    final double strokeWidth = focused ? m.focusRing : m.hairline;
    final double scale = pressed ? 0.985 : 1;

    Widget surface = AnimatedContainer(
      // 「减少动效」开启时动画时长为 0：状态照样切换，只是不做过渡。
      duration: AppMetrics.reduceMotionOf(context, m.hover),
      curve: m.hoverCurve,
      padding: widget.padding,
      transformAlignment: Alignment.center,
      transform: Matrix4.diagonal3Values(scale, scale, 1),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: widget.radius ?? BorderRadius.circular(m.radiusMd),
        border: Border.all(color: stroke, width: strokeWidth),
      ),
      child: widget.child,
    );

    if (interactive) {
      surface = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: surface,
      );
    }

    surface = Focus(
      // 不可交互时既不进入焦点遍历，也不抢任何方向键。
      canRequestFocus: interactive && widget.focusable,
      onFocusChange: _setFocused,
      onKeyEvent: _onKeyEvent,
      child: surface,
    );

    surface = MouseRegion(
      cursor: !interactive
          ? SystemMouseCursors.basic
          : (widget.cursor ?? SystemMouseCursors.click),
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: surface,
    );

    if (!widget.enabled) {
      surface = Opacity(opacity: 0.5, child: surface);
    }
    if (widget.tooltip != null) {
      surface = Tooltip(message: widget.tooltip!, child: surface);
    }
    return surface;
  }
}
