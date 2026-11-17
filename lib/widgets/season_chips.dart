import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/season_number.dart';
import '../models/models.dart';
import '../theme/app_tokens.dart';

/// 选集面板里的「季」标签行。
///
/// 只有多季剧才显示；未上线的季灰显不可点。桌面全屏右侧抽屉与底部选集
/// 共用同一组件，切季行为因此天然一致。
class SeasonChips extends StatelessWidget {
  const SeasonChips({
    super.key,
    required this.seasons,
    required this.currentSeriesId,
    required this.onTap,
  });

  final List<Season> seasons;
  final String currentSeriesId;
  final void Function(Season season) onTap;

  @override
  Widget build(BuildContext context) {
    if (seasons.length <= 1) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = context.app.colors;
    // 桌面端默认 ScrollBehavior 不把鼠标算进拖拽设备（只能滚轮），
    // 多季 chips 超出宽度时鼠标拖不动 → 明确把 mouse 加入 dragDevices。
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: context.app.metrics.s8,
          children: <Widget>[
            for (final (i, season) in seasons.indexed)
              _SeasonChip(
                label: seasonTitleLabel(
                  index: season.index,
                  title: season.title,
                  position: i,
                ),
                selected: season.seriesId == currentSeriesId,
                // 不再拿 episodeCount 当门槛：合集元数据的 count 可能缺新季
                // （万妖 15/16 灰显选不到，用户实测），点进去拉一次才知道
                // 真有没有剧集；空列表在网格区给行内提示。
                enabled: season.seriesId.isNotEmpty &&
                    season.seriesId != currentSeriesId,
                textStyle: theme.textTheme.labelLarge,
                selectedColor: colors.onBrand,
                normalColor: colors.textSecondary,
                backgroundColor: colors.surface2,
                selectedBackground: colors.brand,
                onTap: () => onTap(season),
              ),
          ],
        ),
      ),
    );
  }
}

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.textStyle,
    required this.selectedColor,
    required this.normalColor,
    required this.backgroundColor,
    required this.selectedBackground,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final TextStyle? textStyle;
  final Color selectedColor;
  final Color normalColor;
  final Color backgroundColor;
  final Color selectedBackground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = context.app.metrics;
    return Material(
      color: selected ? selectedBackground : backgroundColor,
      borderRadius: BorderRadius.all(Radius.circular(m.radiusSm)),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.all(Radius.circular(m.radiusSm)),
        child: Padding(
          padding: EdgeInsets.only(
            left: m.s12,
            right: m.s12,
            top: m.s6,
            bottom: m.s6,
          ),
          child: Text(
            label,
            style: textStyle?.copyWith(
              color: selected ? selectedColor : normalColor,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
  }
}
