import 'package:flutter/material.dart';

import '../core/download_service.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import 'player_screen.dart';

/// 我的下载：已缓存剧集列表（封面/集数/体积），点开直接离线播放。
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的下载')),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.downloads, scope.downloads.store]),
        builder: (context, _) {
          final list = scope.downloads.store.seriesList;
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_outlined,
                      size: 56, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('还没有缓存的剧集',
                      style: TextStyle(color: theme.colorScheme.outline)),
                  const SizedBox(height: 8),
                  const Text('在短剧详情页点「缓存」即可离线观看',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text('共 ${list.length} 部 · ${_fmtBytes(scope.downloads.store.totalBytes)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 8),
              for (final s in list)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 44,
                        height: 60,
                        child: CoverImage(url: s.coverUrl),
                      ),
                    ),
                    title: Text(s.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${s.episodes.length}集 · ${_fmtBytes(s.totalBytes)}'
                        '${_activeLabel(scope.downloads, s.seriesId)}'),
                    trailing: IconButton(
                      tooltip: '删除缓存',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('删除《${s.title}》的缓存？'),
                            content: Text(
                                '将删除 ${s.episodes.length} 个已下载分集文件。'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(context, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await scope.downloads.deleteSeries(s.seriesId);
                        }
                      },
                    ),
                    onTap: () => _playOffline(context, scope.downloads, s),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _playOffline(
      BuildContext context, DownloadService service, DownloadedSeries s) {
    final eps = s.episodes
        .map((e) => Episode(
              id: e.episodeId,
              seriesId: e.seriesId,
              number: e.number,
              title: e.title,
            ))
        .toList();
    if (eps.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        series: Series(
          id: s.seriesId,
          title: s.title,
          coverUrl: s.coverUrl,
        ),
        episodes: eps,
        startIndex: 0,
      ),
    ));
  }

  String _activeLabel(DownloadService service, String seriesId) {
    final n = service.activeCount(seriesId);
    return n > 0 ? ' · 下载中 $n 集' : '';
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }
}
