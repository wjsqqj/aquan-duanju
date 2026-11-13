import 'package:flutter/material.dart';

import '../core/download_service.dart';
import '../models/models.dart';
import 'ui/app_icons.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import 'common.dart';
import 'glass/glass_overlay.dart';

/// 离线缓存面板（详情页与播放器选集抽屉共用）：范围、实时进度、取消与删除。
///
/// 外壳走玻璃（`showGlassSheet`，overlay 档）：抓手、圆角、底托都由玻璃层
/// 统一提供；这里只负责内容排版。
Future<void> showDownloadSheet(
  BuildContext context, {
  required Series series,
  required List<Episode> episodes,
}) {
  final service = AppScope.read(context).downloads;
  return showGlassSheet<void>(
    context: context,
    builder: (sheetContext) => ListenableBuilder(
      listenable: Listenable.merge([service, service.store]),
      builder: (context, _) {
        final AppTokens tokens = context.app;
        final AppMetrics m = tokens.metrics;
        final playable = episodes.where((e) => e.playable).toList();
        final downloaded =
            playable.where((e) => service.store.has(e.id)).length;
        final active = service.activeCount(series.id);
        final paused = service.pausedCount(series.id);
        final tasks = service.tasks.values
            .where((t) => t.episode.seriesId == series.id)
            .toList();
        final running =
            tasks.where((t) => t.state == DownloadState.running).toList();
        final pausedTasks =
            tasks.where((t) => t.state == DownloadState.paused).toList();
        final failed =
            tasks.where((t) => t.state == DownloadState.failed).length;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(m.s20, m.s4, m.s20, m.s20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: m.s6,
              children: [
                Text('离线缓存 · ${series.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.title),
                Text(
                  '已缓存 $downloaded / ${playable.length} 集'
                  '${active > 0 ? ' · 下载中 $active 集' : ''}'
                  '${paused > 0 ? ' · 暂停 $paused 集' : ''}'
                  '${failed > 0 ? ' · 失败 $failed 集' : ''}',
                  style: tokens.caption.copyWith(
                    color: tokens.colors.textSecondary,
                  ),
                ),
                if (running.isNotEmpty || pausedTasks.isNotEmpty)
                  for (final t in [
                    ...running.take(1),
                    ...pausedTasks.take(1),
                  ])
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text('第${t.episode.number}集'
                                  ' ${t.episode.title.isEmpty ? '' : t.episode.title}'),
                            ),
                            if (t.state == DownloadState.running)
                              TextButton.icon(
                                onPressed: () =>
                                    service.pauseEpisode(t.episode.id),
                                icon: const Icon(AppIcons.pause, size: 16),
                                label: const Text('暂停'),
                              )
                            else
                              TextButton.icon(
                                onPressed: () =>
                                    service.resumeEpisode(t.episode.id),
                                icon: const Icon(AppIcons.play, size: 16),
                                label: const Text('继续'),
                              ),
                          ],
                        ),
                        LinearProgressIndicator(
                            value: t.progress > 0 ? t.progress : null),
                      ],
                    ),
                if (active > 0 || paused > 0 || failed > 0)
                  Wrap(
                    spacing: m.s4,
                    children: [
                      if (active > 0)
                        TextButton(
                          onPressed: () => service.pauseSeries(series.id),
                          child: const Text('全部暂停'),
                        ),
                      if (paused > 0)
                        TextButton(
                          onPressed: () => service.resumeSeries(series.id),
                          child: const Text('全部继续'),
                        ),
                      if (failed > 0)
                        TextButton(
                          onPressed: () {
                            final n = service.retryFailed(series.id);
                            if (n > 0) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                  SnackBar(content: Text('已重新加入 $n 集')));
                            }
                          },
                          child: Text('重试失败 ($failed)'),
                        ),
                    ],
                  ),
                // 操作行前多一档呼吸（s6 队内 + s6 补偿 = 12）。
                Padding(
                  padding: EdgeInsets.only(top: m.s6),
                  child: Row(
                    spacing: m.s8,
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
                          icon: const Icon(Icons.download_rounded),
                          label: Text(
                              downloaded >= playable.length ? '重新补缺' : '缓存全剧'),
                        ),
                      ),
                      if (active > 0 || paused > 0)
                        OutlinedButton(
                          onPressed: () => service.cancelSeries(series.id),
                          child: const Text('取消下载'),
                        ),
                      if (downloaded > 0 && active == 0)
                        OutlinedButton(
                          onPressed: () async {
                            await service.deleteSeries(series.id);
                          },
                          child: const Text('删除缓存'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
