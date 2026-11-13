import 'package:flutter/material.dart';

import '../../theme/app_color.dart';
import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';

/// 角标语义色。色相由 Token 决定，调用方只说「这是品牌色 / 成功 / 警告」。
enum AppBadgeTone { brand, neutral, success, warning, danger }

/// 角标尺寸档：`sm` 用于封面角标与标签，`md` 用于区块内的状态徽章。
enum AppBadgeSize { sm, md }

/// 胶囊角标：名次 / 「广告」/ 状态 / 标签（design.md §5.2 的 `badge` 复用点）。
///
/// 圆角固定 `radiusPill`、字阶固定 `micro`，不开放自由尺寸——角标满屏都是，
/// 一旦允许逐处微调，「第1」和「广告」就会慢慢长得不一样。
///
/// 背景是**不透明**的（深层色用 [Color.alphaBlend] 压到 `surface1` 上）：
/// 角标经常压在封面图上，半透明底会让深浅两种封面读出两种颜色。
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.text,
    this.tone = AppBadgeTone.brand,
    this.size = AppBadgeSize.sm,
  });

  final String text;
  final AppBadgeTone tone;
  final AppBadgeSize size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.app;
    final AppColors colors = tokens.colors;
    final AppMetrics m = tokens.metrics;

    // (前景, 背景)：背景一律由 Token 色叠到 surface1 上，得到不透明版本。
    final (Color fg, Color bg) = switch (tone) {
      AppBadgeTone.brand => (colors.onBrand, colors.brand),
      AppBadgeTone.neutral => (colors.textSecondary, colors.surface2),
      AppBadgeTone.success => _tinted(colors.success, colors),
      AppBadgeTone.warning => _tinted(colors.warning, colors),
      AppBadgeTone.danger => _tinted(colors.danger, colors),
    };

    final EdgeInsets padding = switch (size) {
      AppBadgeSize.sm => EdgeInsets.symmetric(
        horizontal: m.s6,
        vertical: m.s2,
      ),
      AppBadgeSize.md => EdgeInsets.symmetric(
        horizontal: m.s8,
        vertical: m.s4,
      ),
    };

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(m.radiusPill),
        border: Border.all(color: colors.hairline, width: m.hairline),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.micro.copyWith(color: fg),
      ),
    );
  }

  /// 语义色 @18% 叠到卡片底色上：既保留色相，又不透明。
  static (Color, Color) _tinted(Color color, AppColors colors) => (
    color,
    Color.alphaBlend(color.withValues(alpha: 0.18), colors.surface1),
  );
}
