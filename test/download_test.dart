import 'dart:async';
import 'dart:io';

import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Episode ep(int n, {String seriesId = 's1', bool playable = true}) => Episode(
      id: 's1-e$n',
      seriesId: seriesId,
      number: n,
      title: '第$n集',
      playable: playable,
    );

Series series() => const Series(id: 's1', title: '测试剧');

DownloadService makeService(
  DownloadStore store,
  Directory baseDir, {
  required MediaResolver resolver,
  EpisodeDownloader? downloader,
}) =>
    DownloadService(
      store: store,
      baseDir: baseDir,
      resolver: resolver,
      downloader: downloader,
    );

/// 等服务队列跑完（isBusy 变 false 且二次确认不再变化）。
Future<void> _drain(DownloadService service) async {
  for (var i = 0; i < 200; i++) {
    if (!service.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!service.isBusy) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('下载队列 4 秒内未跑完');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_dl_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  group('DownloadStore', () {
    test('记录/查询/按集数排序/删除', () async {
      final s = DownloadStore();
      await s.record(DownloadEntry(
          seriesId: 's1',
          seriesTitle: '剧',
          coverUrl: 'c',
          episodeId: 'e2',
          number: 2,
          title: '',
          filePath: '/x/第002集.mp4',
          sizeBytes: 20,
          keyHex: 'aa',
          quality: 'best',
          downloadedAt: DateTime.now()));
      await s.record(DownloadEntry(
          seriesId: 's1',
          seriesTitle: '剧',
          coverUrl: 'c',
          episodeId: 'e1',
          number: 1,
          title: '',
          filePath: '/x/第001集.mp4',
          sizeBytes: 10,
          keyHex: 'bb',
          quality: 'best',
          downloadedAt: DateTime.now()));
      expect(s.has('e1'), isTrue);
      expect(s.episodesOf('s1').map((e) => e.number).toList(), [1, 2]);
      expect(s.totalBytes, 30);
      expect(s.seriesList.single.episodes.length, 2);
      await s.removeEpisode('e1');
      expect(s.has('e1'), isFalse);
      expect(s.seriesList.single.episodes.length, 1);
      await s.removeSeries('s1');
      expect(s.seriesList, isEmpty);
    });

    test('持久化往返', () async {
      final first = DownloadStore();
      await first.record(DownloadEntry(
          seriesId: 's1',
          seriesTitle: '剧',
          coverUrl: 'c',
          episodeId: 'e1',
          number: 1,
          title: '',
          filePath: '/x/第001集.mp4',
          sizeBytes: 10,
          keyHex: 'aa',
          quality: '360p',
          downloadedAt: DateTime.parse('2026-10-29T10:00:00.000')));
      final second = DownloadStore();
      await second.ensureLoaded();
      final e = second.entryOf('e1')!;
      expect(e.keyHex, 'aa');
      expect(e.quality, '360p');
      expect(e.downloadedAt, DateTime.parse('2026-10-29T10:00:00.000'));
    });
  });

  group('DownloadService', () {
    test('顺序下载全部集并记录密钥与文件', () async {
      final store = DownloadStore();
      final dir = Directory('${support.path}/downloads');
      final service = makeService(
        store,
        dir,
        resolver: (ep) async => ResolvedMedia(
            url: 'https://cdn.test/${ep.id}.mp4',
            keyHex: 'k${ep.number}',
            quality: '540p'),
        downloader: (url, path, onProgress, isCancelled) async {
          File(path).writeAsBytesSync([1, 2, 3, 4]);
          onProgress?.call(4, 4);
          return 4;
        },
      );
      service.enqueue(series(), [ep(2), ep(1)]);
      await _drain(service);
      expect(store.episodesOf('s1').length, 2);
      expect(store.entryOf('s1-e1')!.keyHex, 'k1');
      expect(store.entryOf('s1-e1')!.quality, '540p');
      expect(service.taskOf('s1-e1')!.state, DownloadState.done);
      // 文件按「第NNN集.mp4」落盘且存在
      final path = store.entryOf('s1-e2')!.filePath;
      expect(path.endsWith('第002集.mp4'), isTrue);
      expect(File(path).existsSync(), isTrue);
    });

    test('已缓存的集跳过', () async {
      final store = DownloadStore();
      final dir = Directory('${support.path}/downloads');
      var downloads = 0;
      final service = makeService(
        store,
        dir,
        resolver: (ep) async => ResolvedMedia(url: 'u'),
        downloader: (url, path, onProgress, isCancelled) async {
          downloads++;
          File(path).writeAsBytesSync([1]);
          return 1;
        },
      );
      await store.record(DownloadEntry(
          seriesId: 's1',
          seriesTitle: '剧',
          coverUrl: 'c',
          episodeId: 's1-e1',
          number: 1,
          title: '',
          filePath: '/x/第001集.mp4',
          sizeBytes: 9,
          keyHex: '',
          quality: '',
          downloadedAt: DateTime.now()));
      final added = service.enqueue(series(), [ep(1), ep(2)]);
      expect(added, 1, reason: '已缓存的第1集不入队');
      await _drain(service);
      expect(downloads, 1);
      expect(store.has('s1-e1'), isTrue);
      expect(store.has('s1-e2'), isTrue);
    });

    test('取消后不再继续下载后续集，且不算失败', () async {
      final store = DownloadStore();
      final dir = Directory('${support.path}/downloads');
      var downloads = 0;
      // 卡住第 2 集：等它开始后再取消，验证队列余量不再下载。
      final e2Started = Completer<void>();
      final release = Completer<void>();
      final service = makeService(
        store,
        dir,
        resolver: (ep) async => ResolvedMedia(url: 'u'),
        downloader: (url, path, onProgress, isCancelled) async {
          if (path.endsWith('第002集.mp4.part')) {
            e2Started.complete();
            await release.future;
          }
          if (isCancelled()) throw StateError('cancelled');
          downloads++;
          File(path).writeAsBytesSync([1]);
          return 1;
        },
      );
      service.enqueue(series(), [ep(1), ep(2), ep(3)]);
      await e2Started.future;
      service.cancelSeries('s1');
      release.complete();
      await _drain(service);
      expect(service.taskOf('s1-e1')!.state, DownloadState.done);
      expect(service.taskOf('s1-e2')!.state, DownloadState.cancelled);
      expect(service.taskOf('s1-e3')!.state, DownloadState.cancelled);
      expect(downloads, 1, reason: '取消后不再写文件');
      expect(store.episodesOf('s1').length, 1);
    });

    test('单集失败继续下一集，临时文件被清理', () async {
      final store = DownloadStore();
      final dir = Directory('${support.path}/downloads');
      var calls = 0;
      final service = makeService(
        store,
        dir,
        resolver: (ep) async => ResolvedMedia(url: 'u'),
        downloader: (url, path, onProgress, isCancelled) async {
          calls++;
          if (calls == 1) {
            File(path).writeAsBytesSync([1]);
            throw const HttpException('boom');
          }
          File(path).writeAsBytesSync([1]);
          return 1;
        },
      );
      service.enqueue(series(), [ep(1), ep(2)]);
      await _drain(service);
      expect(service.taskOf('s1-e1')!.state, DownloadState.failed);
      expect(service.taskOf('s1-e2')!.state, DownloadState.done);
      expect(store.has('s1-e2'), isTrue);
      // 失败集的 .part 已清理
      final parts = Directory('${dir.path}/s1')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'))
          .toList();
      expect(parts, isEmpty);
    });

    test('deleteEpisode 删文件与记录，返回释放字节', () async {
      final store = DownloadStore();
      final dir = Directory('${support.path}/downloads');
      final service = makeService(
        store,
        dir,
        resolver: (ep) async => ResolvedMedia(url: 'u'),
        downloader: (url, path, onProgress, isCancelled) async {
          File(path).writeAsBytesSync([1, 2, 3]);
          return 3;
        },
      );
      service.enqueue(series(), [ep(1), ep(2)]);
      await _drain(service);
      final freed = await service.deleteEpisode('s1-e1');
      expect(freed, 3);
      expect(store.has('s1-e1'), isFalse);
      expect(store.has('s1-e2'), isTrue);
      expect(File(store.entryOf('s1-e2')!.filePath).existsSync(), isTrue);
    });
  });

  group('HistoryStore/FollowStore refreshCovers', () {
    test('URL 变化才更新，空 URL 忽略', () async {
      final h = HistoryStore();
      await h.record(
          seriesId: 's1',
          title: '剧',
          coverUrl: 'old',
          episode: 1,
          episodes: 2,
          episodeId: 'e1',
          position: 0,
          finished: false);
      expect(await h.refreshCovers({'s1': 'old'}), 0);
      expect(await h.refreshCovers({'s1': ''}), 0);
      expect(await h.refreshCovers({'s1': 'new'}), 1);
      expect(h.get('s1')!.coverUrl, 'new');
      // 持久化
      final fresh = HistoryStore();
      await fresh.ensureLoaded();
      expect(fresh.get('s1')!.coverUrl, 'new');

      final f = FollowStore();
      await f.toggle(
          seriesId: 's2', title: '剧2', coverUrl: 'old2', episodeCount: 3);
      // 封面与集数一起刷新；集数变多标记有更新。
      expect(
          await f.refreshFromDetails([
            const Series(id: 's2', title: '剧2', coverUrl: 'new2', episodeCount: 5),
          ]),
          1);
      final entry = f.get('s2')!;
      expect(entry.coverUrl, 'new2');
      expect(entry.latestEpisodeCount, 5);
      expect(entry.hasUpdate, isTrue);
      // 追平后清除更新标记
      await f.ackUpdate('s2', 5);
      expect(f.get('s2')!.hasUpdate, isFalse);
    });
  });
}
