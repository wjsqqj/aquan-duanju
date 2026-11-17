import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/player_overlay_theme.dart';
import 'episode_grid.dart';
import 'season_chips.dart';
import 'ui/app_gap.dart';
import 'ui/app_icons.dart';

/// PC 全屏播放时从右侧滑出的选集抽屉。
///
/// 与底部选集抽屉共用 [EpisodeGrid]：当前集高亮并居中、已看完打勾、离线角标
/// 一致；点任一集回调给播放器走同一个 `_openEpisode` 路径。
class PlayerEpisodeDrawer extends StatelessWidget {
  const PlayerEpisodeDrawer({
    super.key,
    required this.title,
    required this.episodes,
    required this.currentIndex,
    required this.onSelect,
    required this.onClose,
    this.watchedEpisodes = const <int>{},
    this.isDownloaded,
    this.seasons = const <Season>[],
    this.currentSeriesId = '',
    this.onSeasonTap,
  });

  final String title;
  final List<Episode> episodes;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;
  final Set<int> watchedEpisodes;
  final bool Function(Episode episode)? isDownloaded;

  /// 多季剧的季标签（与底部选集面板共用同一套切季回调）。
  final List<Season> seasons;
  final String currentSeriesId;
  final void Function(Season season)? onSeasonTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: PlayerOverlayTokens.panelFill,
      child: SafeArea(
        left: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '选集 · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlayerOverlayTokens.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '收起选集',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      AppIcons.close,
                      size: 18,
                      color: PlayerOverlayTokens.textSecondary,
                    ),
                    onPressed: onClose,
                  ),
                ],
              ),
              Text(
                '${episodes.length}集 · 点任意一集立即播放',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlayerOverlayTokens.textTertiary,
                ),
              ),
              AppGap.v(AppGapSize.s12),
              if (seasons.length > 1 && onSeasonTap != null)
                SeasonChips(
                  seasons: seasons,
                  currentSeriesId: currentSeriesId,
                  onTap: (season) {
                    onClose();
                    onSeasonTap!(season);
                  },
                ),
              if (seasons.length > 1 && onSeasonTap != null)
                AppGap.v(AppGapSize.s12),
              Expanded(
                child: EpisodeGrid(
                  episodes: episodes,
                  currentIndex: currentIndex,
                  onSelect: onSelect,
                  watchedEpisodes: watchedEpisodes,
                  isDownloaded: isDownloaded,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
