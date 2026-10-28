import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../store/stores.dart';
import 'aqua_api.dart';

/// 一次下载解析的结果：媒体 URL 与随文件缓存的 CENC 密钥（未加密为空）。
class ResolvedMedia {
  const ResolvedMedia({
    required this.url,
    this.keyHex = '',
    this.expectedBytes = 0,
  });

  final String url;
  final String keyHex;
  final int expectedBytes;
}

/// 在线解析一集：返回流 URL 与密钥。可注入替换用于测试。
typedef MediaResolver = Future<ResolvedMedia> Function(Episode episode);

/// 单集下载执行器：把 url 下载到 path，报告进度；[isCancelled] 变 true 时
/// 应尽快以异常退出（临时文件由服务清理）。可注入替换用于测试。
typedef EpisodeDownloader = Future<int> Function(
  String url,
  String path,
  void Function(int received, int total)? onProgress,
  bool Function() isCancelled,
);

/// 在线解析（默认实现）：按清晰度选流并取 CENC 密钥。
MediaResolver defaultResolver(AquaApi api, String Function() qualityOf) {
  return (ep) async {
    final pb = await api.resolvePlayback(ep.id);
    final usable = pb.playback.streams.where((s) => s.url.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw StateError('没有可用播放流');
    }
    final quality = qualityOf();
    VideoStream pick;
    switch (quality) {
      case 'worst':
        pick = usable.first;
        break;
      case '':
      case 'best':
        pick = usable.last;
        break;
      default:
        pick = usable.lastWhere(
          (s) =>
              s.definition == quality ||
              s.quality == quality ||
              s.codec == quality,
          orElse: () => usable.last,
        );
    }
    return ResolvedMedia(
      url: pick.url,
      keyHex: pb.contentKey?.key ?? '',
      expectedBytes: pick.size,
    );
  };
}

enum DownloadState { queued, running, done, failed, cancelled }

/// 一集的下载任务状态（UI 订阅服务刷新）。
class DownloadTask {
  DownloadTask(this.episode, this.seriesTitle, this.coverUrl);

  final Episode episode;
  final String seriesTitle;
  final String coverUrl;
  DownloadState state = DownloadState.queued;
  int received = 0;
  int total = 0;
  Object? error;

  double get progress =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
}

/// 离线下载服务：顺序队列，逐集「在线解析 → 流式下载 .part → 改名 → 记录」。
///
/// 加密分集的密钥按集稳定，与文件一起记进 [DownloadStore]；离线播放时
/// 播放器对本地文件用 decryption_key 解密即可，全程不需要网络。
class DownloadService extends ChangeNotifier {
  DownloadService({
    required this.store,
    required this.baseDir,
    required this.resolver,
    EpisodeDownloader? downloader,
  }) : downloader = downloader ?? defaultDownloader;

  final DownloadStore store;
  final Directory baseDir;
  final MediaResolver resolver;
  final EpisodeDownloader downloader;

  final Map<String, DownloadTask> _tasks = {};
  final List<Episode> _queue = [];
  final Set<String> _cancelledSeries = {};
  bool _pumping = false;

  /// 全部任务（含已完成），episodeId → task。
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  DownloadTask? taskOf(String episodeId) => _tasks[episodeId];

  /// 某部剧的活动任务（排队/进行中）数量。
  int activeCount(String seriesId) => _tasks.values
      .where((t) =>
          t.episode.seriesId == seriesId &&
          (t.state == DownloadState.queued || t.state == DownloadState.running))
      .length;

  bool get isBusy => _pumping;

  /// 把一部剧未缓存的集加入队列；返回本次入队的集数。
  int enqueue(Series series, List<Episode> episodes) {
    var added = 0;
    _cancelledSeries.remove(series.id);
    for (final ep in episodes) {
      if (!ep.playable) continue;
      if (store.has(ep.id)) continue;
      final existing = _tasks[ep.id];
      if (existing != null &&
          (existing.state == DownloadState.queued ||
              existing.state == DownloadState.running)) {
        continue;
      }
      _tasks[ep.id] = DownloadTask(ep, series.title, series.coverUrl);
      _queue.add(ep);
      added++;
    }
    if (added > 0) {
      notifyListeners();
      unawaited(_pump());
    }
    return added;
  }

  /// 取消一部剧：排队中的直接标记，正在下载的由下载循环按集退出。
  void cancelSeries(String seriesId) {
    _cancelledSeries.add(seriesId);
    _queue.removeWhere((ep) => ep.seriesId == seriesId);
    for (final t in _tasks.values) {
      if (t.episode.seriesId == seriesId && t.state == DownloadState.queued) {
        t.state = DownloadState.cancelled;
      }
    }
    notifyListeners();
  }

  /// 删除一部剧的缓存文件与记录；返回释放的字节数。
  Future<int> deleteSeries(String seriesId) async {
    final eps = store.episodesOf(seriesId);
    var freed = 0;
    for (final e in eps) {
      try {
        final f = File(e.filePath);
        if (await f.exists()) {
          freed += await f.length();
          await f.delete();
        }
      } catch (_) {}
    }
    final dir = Directory('${baseDir.path}${Platform.pathSeparator}$seriesId');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    await store.removeSeries(seriesId);
    return freed;
  }

  /// 播放源：已缓存返回本地记录；未缓存返回 null（调用方在线解析）。
  DownloadEntry? localEntryOf(String episodeId) => store.entryOf(episodeId);

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final ep = _queue.removeAt(0);
        final task = _tasks[ep.id];
        if (task == null) continue;
        if (_cancelledSeries.contains(ep.seriesId)) {
          task.state = DownloadState.cancelled;
          notifyListeners();
          continue;
        }
        task.state = DownloadState.running;
        notifyListeners();
        try {
          final resolved = await resolver(ep);
          final dir = Directory(
              '${baseDir.path}${Platform.pathSeparator}${ep.seriesId}');
          await dir.create(recursive: true);
          final path =
              '${dir.path}${Platform.pathSeparator}第${_pad3(ep.number)}集.mp4';
          task.total = resolved.expectedBytes > 0 ? resolved.expectedBytes : 0;
          final size = await downloader(
            resolved.url,
            '$path.part',
            (received, total) {
              task.received = received;
              task.total = total;
              notifyListeners();
            },
            () => _cancelledSeries.contains(ep.seriesId),
          );
          if (_cancelledSeries.contains(ep.seriesId)) {
            task.state = DownloadState.cancelled;
          } else {
            await File('$path.part').rename(path);
            await store.record(DownloadEntry(
              seriesId: ep.seriesId,
              seriesTitle: task.seriesTitle,
              coverUrl: task.coverUrl,
              episodeId: ep.id,
              number: ep.number,
              title: ep.title,
              filePath: path,
              sizeBytes: size,
              keyHex: resolved.keyHex,
              quality: 'download',
              downloadedAt: DateTime.now(),
            ));
            task.state = DownloadState.done;
            task.received = task.total = size;
          }
        } catch (e) {
          task.state = _cancelledSeries.contains(ep.seriesId)
              ? DownloadState.cancelled
              : DownloadState.failed;
          task.error = e;
          await _cleanParts(ep.seriesId);
        }
        notifyListeners();
      }
    } finally {
      _pumping = false;
      notifyListeners();
    }
  }

  /// 清掉该剧目录下的 .part 临时文件。
  Future<void> _cleanParts(String seriesId) async {
    try {
      final dir =
          Directory('${baseDir.path}${Platform.pathSeparator}$seriesId');
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.part')) {
          await f.delete();
        }
      }
    } catch (_) {}
  }
}

/// 默认下载执行器：流式写 .part，按块检查取消标记。
Future<int> defaultDownloader(
  String url,
  String path,
  void Function(int received, int total)? onProgress,
  bool Function() isCancelled,
) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('下载失败：HTTP ${response.statusCode}');
    }
    final total = response.contentLength ?? 0;
    final sink = File(path).openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        if (isCancelled()) {
          throw StateError('cancelled');
        }
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return received;
  } finally {
    client.close();
  }
}

String _pad3(int n) => n.toString().padLeft(3, '0');
