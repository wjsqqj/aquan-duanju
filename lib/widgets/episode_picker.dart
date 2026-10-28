import 'package:flutter/material.dart';

import '../models/models.dart';

/// 播放器选集抽屉：集数网格，当前集高亮，点任意集回调。
///
/// 独立无状态组件，不依赖播放器与 FFI，可纯 widget 测试。
class EpisodePickerSheet extends StatelessWidget {
  const EpisodePickerSheet({
    super.key,
    required this.title,
    required this.episodes,
    required this.currentIndex,
    required this.onSelect,
    this.isDownloaded,
    this.onDownload,
  });

  final String title;
  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// 可选：该集是否已离线缓存（角标用）。
  final bool Function(Episode episode)? isDownloaded;

  /// 可选：头部「缓存」按钮（播放中直接发起离线缓存）。
  final VoidCallback? onDownload;

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
                    icon: const Icon(Icons.download_outlined, size: 20),
                    onPressed: onDownload,
                  ),
                Text('${episodes.length}集',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                itemCount: episodes.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 72,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.6,
                ),
                itemBuilder: (context, i) {
                  final current = i == currentIndex;
                  final ep = episodes[i];
                  final label = ep.title.trim().isNotEmpty
                      ? ep.title.trim()
                      : '${i + 1}';
                  return _EpisodeCell(
                    label: label,
                    current: current,
                    locked: !ep.playable,
                    downloaded: isDownloaded?.call(ep) ?? false,
                    onTap: () => onSelect(i),
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

class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.label,
    required this.current,
    required this.locked,
    required this.downloaded,
    required this.onTap,
  });

  final String label;
  final bool current;
  final bool locked;
  final bool downloaded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: current
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: locked ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: current
                    ? theme.colorScheme.onPrimary
                    : (locked ? theme.colorScheme.outline : null),
                fontWeight: current ? FontWeight.bold : null,
              ),
            ),
            if (downloaded)
              Positioned(
                right: 3,
                top: 3,
                child: Icon(Icons.download_done,
                    size: 13,
                    color: current
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary),
              ),
          ],
        ),
      ),
    );
  }
}

/// 打开选集抽屉；选择后先关抽屉再回调下标。
Future<void> showEpisodePicker(
  BuildContext context, {
  required String title,
  required List<Episode> episodes,
  required int currentIndex,
  required ValueChanged<int> onSelect,
  bool Function(Episode episode)? isDownloaded,
  VoidCallback? onDownload,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.65,
    ),
    builder: (_) => EpisodePickerSheet(
      title: title,
      episodes: episodes,
      currentIndex: currentIndex,
      onSelect: (i) {
        Navigator.of(context).pop();
        onSelect(i);
      },
      isDownloaded: isDownloaded,
      onDownload: onDownload,
    ),
  );
}
