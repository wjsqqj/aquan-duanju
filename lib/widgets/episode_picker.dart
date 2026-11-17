import 'package:flutter/material.dart';

import '../models/models.dart';
import 'episode_grid.dart';
import 'jelly/jelly_sheet_reveal.dart';
import 'season_browse_controller.dart';
import 'season_chips.dart';
import 'ui/app_gap.dart';
import 'ui/app_icons.dart';

/// 播放器选集抽屉：集数网格，当前集高亮，点任意集回调。
///
/// 网格本体（定位 / 打勾 / 角标）在 [EpisodeGrid]，与全屏右侧边缘抽屉共用；
/// 这里只负责底部抽屉的外壳与头部。
///
/// 二轮反馈行为变更：多季剧点季标签**只切换浏览的季**（看那一季有多少集），
/// 不再直接起播；只有点到某一集才播放（跨季时切到对应季的对应集）。
class EpisodePickerSheet extends StatefulWidget {
  const EpisodePickerSheet({
    super.key,
    required this.title,
    required this.episodes,
    required this.currentIndex,
    required this.playingSeriesId,
    required this.seasons,
    required this.fetchSeasonEpisodes,
    required this.onSelect,
    required this.onPlaySeasonEpisode,
    this.isDownloaded,
    this.onDownload,
    this.watchedEpisodes = const <int>{},
  });

  final String title;

  /// 正在播的季的集数列表。
  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;

  /// 正在播的季 id。
  final String playingSeriesId;

  /// 多季剧的季标签（≤1 季时组件自己不渲染）。
  final List<Season> seasons;

  /// 拉取某季全部集数（播放器侧统一分页聚合）。
  final Future<List<Episode>> Function(String seriesId) fetchSeasonEpisodes;

  /// 点播放季的某一集：回调集下标。
  final ValueChanged<int> onSelect;

  /// 点其它季的某一集：回调（那一季, 该季内下标），由播放器切季起播。
  final void Function(Season season, int indexInSeason) onPlaySeasonEpisode;

  /// 已看完的集号（[Episode.number]，从 1 开始），右下角打勾。
  final Set<int> watchedEpisodes;

  /// 可选：该集是否已离线缓存（角标用）。
  final bool Function(Episode episode)? isDownloaded;

  /// 可选：头部「缓存」按钮（播放中直接发起离线缓存）。
  final VoidCallback? onDownload;

  @override
  State<EpisodePickerSheet> createState() => _EpisodePickerSheetState();
}

class _EpisodePickerSheetState extends State<EpisodePickerSheet> {
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
    Navigator.of(context).pop();
    if (_browse.browsingPlayingSeason) {
      widget.onSelect(indexInSeason);
    } else {
      widget.onPlaySeasonEpisode(_browse.current, indexInSeason);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedBuilder(
              animation: _browse,
              builder: (context, _) {
                final season = _browse.current;
                final browsingOther =
                    !_browse.browsingPlayingSeason && season.title.isNotEmpty;
                return Row(
                  children: [
                    Expanded(
                      child: Text(
                        browsingOther
                            ? '选集 · ${season.title}'
                            : '选集 · ${widget.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (widget.onDownload != null)
                      IconButton(
                        tooltip: '缓存全剧',
                        icon: const Icon(AppIcons.download, size: 20),
                        onPressed: widget.onDownload,
                      ),
                    Text('${_browse.episodes.length}集',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ],
                );
              },
            ),
            AppGap.v(AppGapSize.s12),
            if (widget.seasons.length > 1)
              AnimatedBuilder(
                animation: _browse,
                builder: (context, _) => SeasonChips(
                  seasons: widget.seasons,
                  currentSeriesId: _browse.current.seriesId,
                  // 点季只浏览：失败在控制器里回退到上一个季，行内提示。
                  onTap: (season) =>
                      _browse.browse(season).catchError((_) {}),
                ),
              ),
            if (widget.seasons.length > 1) AppGap.v(AppGapSize.s12),
            Flexible(
              child: AnimatedBuilder(
                animation: _browse,
                builder: (context, _) {
                  if (_browse.loading && _browse.episodes.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  if (_browse.loadFailed && _browse.episodes.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          '该季集数加载失败，请稍后重试',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
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
    );
  }
}

/// 打开选集抽屉；选择后先关抽屉再回调下标。
///
/// 外壳走玻璃（③ 接线）：`showGlassSheet` + 凝胶展开入场；选集网格本身
/// 保持实体（§11.5 第 2 条：列表内部不得逐项玻璃）。
Future<void> showEpisodePicker(
  BuildContext context, {
  required String title,
  required List<Episode> episodes,
  required int currentIndex,
  required String playingSeriesId,
  required List<Season> seasons,
  required Future<List<Episode>> Function(String seriesId) fetchSeasonEpisodes,
  required ValueChanged<int> onSelect,
  required void Function(Season season, int indexInSeason)
      onPlaySeasonEpisode,
  bool Function(Episode episode)? isDownloaded,
  VoidCallback? onDownload,
  Set<int> watchedEpisodes = const <int>{},
}) {
  // 玻璃在播放器上下文不可见（批次⑤实测）→ 选集抽屉退回实体表面。
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.65,
    ),
    builder: (_) => JellySheetReveal(
      child: EpisodePickerSheet(
        title: title,
        episodes: episodes,
        currentIndex: currentIndex,
        playingSeriesId: playingSeriesId,
        seasons: seasons,
        fetchSeasonEpisodes: fetchSeasonEpisodes,
        onSelect: onSelect,
        onPlaySeasonEpisode: onPlaySeasonEpisode,
        isDownloaded: isDownloaded,
        onDownload: onDownload,
        watchedEpisodes: watchedEpisodes,
      ),
    ),
  );
}
