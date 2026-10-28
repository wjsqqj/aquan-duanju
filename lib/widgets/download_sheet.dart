import 'package:flutter/material.dart';

import '../core/download_service.dart';
import '../models/models.dart';
import 'common.dart';

/// 离线缓存面板（详情页与播放器选集抽屉共用）：范围、实时进度、取消与删除。
Future<void> showDownloadSheet(
  BuildContext context, {
  required Series series,
  required List<Episode> episodes,
}) {
  final service = AppScope.read(context).downloads;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: Listenable.merge([service, service.store]),
      builder: (context, _) {
        final playable = episodes.where((e) => e.playable).toList();
        final downloaded =
            playable.where((e) => service.store.has(e.id)).length;
        final active = service.activeCount(series.id);
        final tasks = service.tasks.values
            .where((t) => t.episode.seriesId == series.id)
            .toList();
        final running =
            tasks.where((t) => t.state == DownloadState.running).toList();
        final failed =
            tasks.where((t) => t.state == DownloadState.failed).length;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('离线缓存 · ${series.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                  '已缓存 $downloaded / ${playable.length} 集'
                  '${active > 0 ? ' · 下载中 $active 集' : ''}'
                  '${failed > 0 ? ' · 失败 $failed 集' : ''}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                if (running.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final t in running.take(1))
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('第${t.episode.number}集'
                            ' ${t.episode.title.isEmpty ? '' : t.episode.title}'),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                            value: t.progress > 0 ? t.progress : null),
                      ],
                    ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: active > 0
                            ? null
                            : () {
                                final added =
                                    service.enqueue(series, playable);
                                Navigator.pop(sheetContext);
                                ScaffoldMessenger.maybeOf(context)
                                    ?.showSnackBar(SnackBar(
                                    content: Text(added > 0
                                        ? '已加入 $added 集下载队列'
                                        : '没有需要下载的集')));
                              },
                        icon: const Icon(Icons.download_outlined),
                        label: Text(
                            downloaded >= playable.length ? '重新补缺' : '缓存全剧'),
                      ),
                    ),
                    if (active > 0) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () => service.cancelSeries(series.id),
                        child: const Text('取消下载'),
                      ),
                    ],
                    if (downloaded > 0 && active == 0) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () async {
                          await service.deleteSeries(series.id);
                        },
                        child: const Text('删除缓存'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
