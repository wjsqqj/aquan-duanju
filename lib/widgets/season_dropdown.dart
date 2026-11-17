import 'package:flutter/material.dart';

import '../core/season_number.dart';
import '../models/models.dart';
import '../theme/player_overlay_theme.dart';
import 'ui/app_icons.dart';

/// 桌面全屏右侧选集抽屉的「季」下拉选择。
///
/// 二轮反馈：多季（如《万妖图录传》九季）用 chips 横向滚动在桌面端
/// 拖不动、看不全，改成下拉。点下拉项只切换**浏览**的季，不起播。
class SeasonDropdown extends StatelessWidget {
  const SeasonDropdown({
    super.key,
    required this.seasons,
    required this.currentSeriesId,
    required this.playingSeriesId,
    required this.onChanged,
    this.onMenuOpenChanged,
  });

  final List<Season> seasons;

  /// 当前**浏览**的季 id（下拉框文案与高亮跟随它）。
  final String currentSeriesId;

  /// 正在播的季 id（菜单里标「正在播放」）。
  final String playingSeriesId;

  final ValueChanged<Season> onChanged;

  /// 菜单开/关通知。抽屉宿主需要它判断「鼠标离开面板」是不是菜单导致的
  /// ——弹出菜单是独立 overlay 路由，菜单一开宿主的 MouseRegion 必然
  /// onExit，不豁免的话抽屉会被 260ms 自动收起、选中结果跟着丢掉。
  final void Function(bool open)? onMenuOpenChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Season current = seasons.first;
    for (final season in seasons) {
      if (season.seriesId == currentSeriesId) {
        current = season;
        break;
      }
    }
    return PopupMenuButton<Season>(
      tooltip: '切换季',
      color: PlayerOverlayTokens.panelFill,
      constraints: const BoxConstraints(maxHeight: 420),
      onOpened: () => onMenuOpenChanged?.call(true),
      onCanceled: () => onMenuOpenChanged?.call(false),
      onSelected: (season) {
        onMenuOpenChanged?.call(false);
        onChanged(season);
      },
      // 集数为 0 的季不进菜单（同 SeasonChips：灰显不如藏掉）；触发器文案
      // 仍从全量 seasons 里取，保证正在播的季（元数据可能缺 count）显示正确。
      itemBuilder: (context) => <PopupMenuEntry<Season>>[
        for (final (i, season) in seasons.indexed)
          if (season.episodeCount > 0)
            PopupMenuItem<Season>(
              value: season,
              enabled: season.seriesId.isNotEmpty,
            child: Row(
              children: <Widget>[
                Icon(
                  season.seriesId == currentSeriesId
                      ? AppIcons.check
                      : null,
                  size: 16,
                  color: PlayerOverlayTokens.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    seasonTitleLabel(
                      index: season.index,
                      title: season.title,
                      position: i,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PlayerOverlayTokens.stylePrimary.copyWith(
                      color: PlayerOverlayTokens.textPrimary,
                    ),
                  ),
                ),
                if (season.seriesId == playingSeriesId) ...<Widget>[
                  const SizedBox(width: 8),
                  Text(
                    '正在播放',
                    style: PlayerOverlayTokens.styleSecondary.copyWith(
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: PlayerOverlayTokens.scrimSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: PlayerOverlayTokens.scrimMedium),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                seasonTitleLabel(
                  index: current.index,
                  title: current.title,
                  position: seasons.indexOf(current),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: PlayerOverlayTokens.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.unfold_more_rounded,
              size: 16,
              color: PlayerOverlayTokens.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
