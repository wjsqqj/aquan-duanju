import 'package:flutter/material.dart';

import '../models/models.dart';
import 'episode_grid.dart';
import 'jelly/jelly_sheet_reveal.dart';
import 'season_chips.dart';
import 'ui/app_gap.dart';
import 'ui/app_icons.dart';

/// 播放器选集抽屉：集数网格，当前集高亮，点任意集回调。
///
/// 网格本体（定位 / 打勾 / 角标）在 [EpisodeGrid]，与全屏右侧边缘抽屉共用；
/// 这里只负责底部抽屉的外壳与头部。
class EpisodePickerSheet extends StatelessWidget {
  const EpisodePickerSheet({
    super.key,
    required this.title,
    required this.episodes,
    required this.currentIndex,
    required this.onSelect,
    this.isDownloaded,
    this.onDownload,
    this.watchedEpisodes = const <int>{},
    this.seasons = const <Season>[],
    this.currentSeriesId = '',
    this.onSeasonTap,
  });

  final String title;
  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// 已看完的集号（[Episode.number]，从 1 开始），右下角打勾。
  final Set<int> watchedEpisodes;

  /// 可选：该集是否已离线缓存（角标用）。
  final bool Function(Episode episode)? isDownloaded;

  /// 可选：头部「缓存」按钮（播放中直接发起离线缓存）。
  final VoidCallback? onDownload;

  /// 多季剧的季标签（≤1 季时组件自己不渲染）。
  final List<Season> seasons;
  final String currentSeriesId;
  final void Function(Season season)? onSeasonTap;

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
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选集 · $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (onDownload != null)
                  IconButton(
                    tooltip: '缓存全剧',
                    icon: const Icon(AppIcons.download, size: 20),
                    onPressed: onDownload,
                  ),
                Text('${episodes.length}集',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
            AppGap.v(AppGapSize.s12),
            if (seasons.length > 1 && onSeasonTap != null)
              SeasonChips(
                seasons: seasons,
                currentSeriesId: currentSeriesId,
                onTap: (season) {
                  Navigator.of(context).pop();
                  onSeasonTap!(season);
                },
              ),
            if (seasons.length > 1 && onSeasonTap != null)
              AppGap.v(AppGapSize.s12),
            Flexible(
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
  required ValueChanged<int> onSelect,
  bool Function(Episode episode)? isDownloaded,
  VoidCallback? onDownload,
  Set<int> watchedEpisodes = const <int>{},
  List<Season> seasons = const <Season>[],
  String currentSeriesId = '',
  void Function(Season season)? onSeasonTap,
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
        onSelect: (i) {
          Navigator.of(context).pop();
          onSelect(i);
        },
        isDownloaded: isDownloaded,
        onDownload: onDownload,
        watchedEpisodes: watchedEpisodes,
        seasons: seasons,
        currentSeriesId: currentSeriesId,
        onSeasonTap: onSeasonTap,
      ),
    ),
  );
}
