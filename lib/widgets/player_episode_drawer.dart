import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/player_overlay_theme.dart';
import 'episode_grid.dart';
import 'season_browse_controller.dart';
import 'season_dropdown.dart';
import 'ui/app_gap.dart';
import 'ui/app_icons.dart';

/// PC 全屏播放时从右侧滑出的选集抽屉。
///
/// 与底部选集抽屉共用 [EpisodeGrid]：当前集高亮并居中、已看完打勾、离线角标
/// 一致；点任一集回调给播放器走同一条起播路径。
///
/// 二轮反馈行为变更：
/// - 季选择改**下拉**（九季剧 chips 桌面端拖不动、看不全）；
/// - 点季只**浏览**该季集数，不起播；点到某一集才播放（跨季切对应集）。
class PlayerEpisodeDrawer extends StatefulWidget {
  const PlayerEpisodeDrawer({
    super.key,
    required this.title,
    required this.episodes,
    required this.currentIndex,
    required this.playingSeriesId,
    required this.seasons,
    required this.fetchSeasonEpisodes,
    required this.onSelect,
    required this.onPlaySeasonEpisode,
    required this.onClose,
    this.onSeasonMenuOpenChanged,
    this.watchedEpisodes = const <int>{},
    this.isDownloaded,
  });

  final String title;

  /// 正在播的季的集数列表。
  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;

  /// 正在播的季 id。
  final String playingSeriesId;

  /// 多季剧的季标签（≤1 季时不渲染季选择）。
  final List<Season> seasons;

  /// 拉取某季全部集数（播放器侧统一分页聚合）。
  final Future<List<Episode>> Function(String seriesId) fetchSeasonEpisodes;

  /// 点播放季的某一集。
  final ValueChanged<int> onSelect;

  /// 点其它季的某一集：回调（那一季, 该季内下标）。
  final void Function(Season season, int indexInSeason) onPlaySeasonEpisode;

  final VoidCallback onClose;

  /// 季下拉菜单开/关（见 [SeasonDropdown.onMenuOpenChanged]）：
  /// 菜单是独立 overlay，宿主要在它打开期间豁免「鼠标离开即收起」。
  final void Function(bool open)? onSeasonMenuOpenChanged;

  final Set<int> watchedEpisodes;
  final bool Function(Episode episode)? isDownloaded;

  @override
  State<PlayerEpisodeDrawer> createState() => _PlayerEpisodeDrawerState();
}

class _PlayerEpisodeDrawerState extends State<PlayerEpisodeDrawer> {
  late final SeasonBrowseController _browse = SeasonBrowseController(
    seasons: widget.seasons,
    playingSeriesId: widget.playingSeriesId,
    playingEpisodes: widget.episodes,
    playingIndex: widget.currentIndex,
    fetchSeasonEpisodes: widget.fetchSeasonEpisodes,
  );

  @override
  void dispose() {
    _browse.dispose();
    super.dispose();
  }

  void _select(int indexInSeason) {
    widget.onClose();
    if (_browse.browsingPlayingSeason) {
      widget.onSelect(indexInSeason);
    } else {
      widget.onPlaySeasonEpisode(_browse.current, indexInSeason);
    }
  }

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
                    child: AnimatedBuilder(
                      animation: _browse,
                      builder: (context, _) {
                        final season = _browse.current;
                        final browsingOther = !_browse.browsingPlayingSeason &&
                            season.title.isNotEmpty;
                        return Text(
                          browsingOther
                              ? '选集 · ${season.title}'
                              : '选集 · ${widget.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: PlayerOverlayTokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
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
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              AnimatedBuilder(
                animation: _browse,
                builder: (context, _) => Text(
                  '${_browse.episodes.length}集 · 点任意一集立即播放',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlayerOverlayTokens.textTertiary,
                  ),
                ),
              ),
              AppGap.v(AppGapSize.s12),
              if (widget.seasons.length > 1)
                AnimatedBuilder(
                  animation: _browse,
                  builder: (context, _) => SeasonDropdown(
                    seasons: widget.seasons,
                    currentSeriesId: _browse.current.seriesId,
                    playingSeriesId: widget.playingSeriesId,
                    onMenuOpenChanged: widget.onSeasonMenuOpenChanged,
                    // 点下拉项只切换浏览的季，不起播。
                    onChanged: (season) =>
                        _browse.browse(season).catchError((_) {}),
                  ),
                ),
              if (widget.seasons.length > 1) AppGap.v(AppGapSize.s12),
              Expanded(
                child: AnimatedBuilder(
                  animation: _browse,
                  builder: (context, _) {
                    if (_browse.loading && _browse.episodes.isEmpty) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }
                    if (_browse.loadFailed && _browse.episodes.isEmpty) {
                      return Center(
                        child: Text(
                          '该季集数加载失败，请稍后重试',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: PlayerOverlayTokens.textTertiary,
                          ),
                        ),
                      );
                    }
                    if (!_browse.loading && _browse.episodes.isEmpty) {
                      return Center(
                        child: Text(
                          '该季还没有可播放的剧集',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: PlayerOverlayTokens.textTertiary,
                          ),
                        ),
                      );
                    }
                    return EpisodeGrid(
                      episodes: _browse.episodes,
                      currentIndex: _browse.currentIndex,
                      onSelect: _select,
                      watchedEpisodes: _browse.browsingPlayingSeason
                          ? widget.watchedEpisodes
                          : const <int>{},
                      isDownloaded: widget.isDownloaded,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
