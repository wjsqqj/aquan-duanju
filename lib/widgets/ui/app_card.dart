import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import 'app_badge.dart';
import 'app_interactive.dart';

/// 卡片形态（design.md §5.2）。
enum AppCardDensity {
  /// 3:4 封面 + 标题 + 副标题 + 可选角标：网格里的主卡片。
  cover,

  /// 16:9 缩略图 + 右侧文字块：继续观看 / 历史 / 推荐。
  wide,

  /// 前导图标或图 + 主标题 + 次行 + 尾部控件：设置项 / 源列表 / 规则列表。
  row,
}

/// 统一卡片：三种密度共用同一套底色、描边、圆角与四态交互。
///
/// - **封面必须由调用方传入**（`image`）：封面要走既有的 `CoverImage`
///   （Go 核心转码 HEIC），本组件不碰 `Image.network`。
/// - **不加任何渐变遮罩**：卡片背景渐变是 design.md §4.6 的白名单外用法，
///   文字的对比度靠 `surface1` 底与字色 Token 保证。
/// - `onTap == null` 时退化为静态容器（同样的外表，但不抢焦点、不响应 hover）。
/// - 交互沿 [AppInteractive]：hover / pressed / focus / disabled 四态一致，
///   不需要每个调用点各写一遍。
class AppCard extends StatelessWidget {
  /// 3:4 封面卡。放进网格时请让单元的 `childAspectRatio` 容得下
  /// 「3:4 封面 + 两行文字」，否则 `AspectRatio` 会被压扁。
  const AppCard.cover({
    super.key,
    required this.image,
    required this.title,
    this.subtitle,
    this.badge,
    this.titleMaxLines = 2,
    this.onTap,
    this.tooltip,
    this.selected = false,
  })  : density = AppCardDensity.cover,
        leading = null,
        trailing = null,
        titleTrailing = null;

  /// 16:9 缩略图 + 右侧文字块。
  const AppCard.wide({
    super.key,
    required this.image,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tooltip,
    this.selected = false,
  })  : density = AppCardDensity.wide,
        badge = null,
        leading = null,
        titleTrailing = null,
        titleMaxLines = 2;

  /// 紧凑行：设置项 / 源列表 / 规则列表。
  const AppCard.row({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.titleTrailing,
    this.onTap,
    this.tooltip,
    this.selected = false,
  })  : density = AppCardDensity.row,
        image = null,
        badge = null,
        titleMaxLines = 2;

  final AppCardDensity density;

  /// 封面 / 缩略图（`cover`、`wide`）；由调用方传入 `CoverImage` 之类。
  final Widget? image;

  /// 主标题。
  final String title;

  /// 副标题（集数 / 分类 / 状态说明）。
  final String? subtitle;

  /// 左上角角标（名次 / 「广告」/ 状态），复用 [AppBadge]。
  final String? badge;

  /// `row` 的前导图标或小图。
  final Widget? leading;

  /// 尾部控件（右侧箭头 / 开关 / 进度文字）。
  final Widget? trailing;

  /// 标题行尾部的小件（「推广」角标等）；仅 `row` 密度生效。
  /// `null` 时标题独占整行。放这里而不是让调用方自己拼 Row——
  /// 拼了就会出现截断语义不一致的平行实现。
  final Widget? titleTrailing;

  /// 标题行数上限（`cover` 用）：密集网格传 1 防止单元溢出，默认 2。
  final int titleMaxLines;

  final VoidCallback? onTap;
  final String? tooltip;
  final bool selected;

  /// `wide` 缩略图宽度：16:9 下得到 72 高，与「继续观看」行的行高同级。
  static const double _thumbWidth = 128;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final BorderRadius radius = BorderRadius.circular(m.radiusMd);

    final Widget content = switch (density) {
      AppCardDensity.cover => _buildCover(context),
      AppCardDensity.wide => _buildWide(context),
      AppCardDensity.row => _buildRow(context),
    };

    if (onTap == null) {
      // 静态容器：外观与可点态完全一致，只是没有四态反馈。
      return DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.colors.surface1,
          borderRadius: radius,
          border: Border.all(
            color: tokens.colors.hairline,
            width: m.hairline,
          ),
        ),
        child: content,
      );
    }

    return AppInteractive(
      onTap: onTap,
      tooltip: tooltip,
      selected: selected,
      radius: radius,
      child: content,
    );
  }

  Widget _buildCover(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final String? badgeText = badge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Stack(
          children: <Widget>[
            ClipRRect(
              // 只有封面贴住卡片顶边，所以只压上侧圆角。
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(m.radiusMd),
              ),
              child: AspectRatio(aspectRatio: 3 / 4, child: image),
            ),
            if (badgeText != null)
              Positioned(
                left: m.s6,
                top: m.s6,
                child: AppBadge(text: badgeText),
              ),
          ],
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(m.s8, m.s6, m.s8, m.s8),
          child: _texts(tokens, crossAxisAlignment: CrossAxisAlignment.start),
        ),
      ],
    );
  }

  Widget _buildWide(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final Widget? trailingWidget = trailing;
    return Padding(
      padding: EdgeInsets.all(m.s8),
      child: Row(
        spacing: m.s12,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(m.radiusSm),
            child: SizedBox(
              width: _thumbWidth,
              child: AspectRatio(aspectRatio: 16 / 9, child: image),
            ),
          ),
          Expanded(child: _texts(tokens)),
          ?trailingWidget,
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    final Widget? leadingWidget = leading;
    final Widget? trailingWidget = trailing;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.s16, vertical: m.s12),
      child: Row(
        spacing: m.s12,
        children: <Widget>[
          ?leadingWidget,
          Expanded(child: _texts(tokens)),
          ?trailingWidget,
        ],
      ),
    );
  }

  /// 标题 + 副标题：三种密度共用同一套字阶与截断规则。
  Widget _texts(
    AppTokens tokens, {
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.center,
  }) {
    final String? sub = subtitle;
    final Widget? titleTrailingWidget =
        density == AppCardDensity.row ? titleTrailing : null;
    final Widget titleWidget = titleTrailingWidget == null
        ? Text(
            title,
            maxLines: density == AppCardDensity.row ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: tokens.title,
          )
        : Row(
            spacing: tokens.metrics.s6,
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.title,
                ),
              ),
              titleTrailingWidget,
            ],
          );
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.metrics.s2,
      children: <Widget>[
        titleWidget,
        if (sub != null)
          Text(
            sub,
            maxLines: density == AppCardDensity.row ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.label.copyWith(color: tokens.colors.textSecondary),
          ),
      ],
    );
  }
}
