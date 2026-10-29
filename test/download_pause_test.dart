import 'dart:io';

import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Episode ep(int n) => Episode(
      id: 's1-e$n',
      seriesId: 's1',
      number: n,
      title: '第$n集',
      playable: true,
    );

Series series() => const Series(id: 's1', title: '测试剧');

/// 每次写 10 字节、可被 isCancelled 打断的下载器。
EpisodeDownloader stepDownloader({
  Duration step = const Duration(milliseconds: 20),
  int chunks = 10,
}) =>
    (url, path, onProgress, isCancelled) async {
      final expected = chunks * 10;
      var received =
          File(path).existsSync() ? File(path).lengthSync() : 0;
      final sink = File(path).openWrite(mode: FileMode.append);
      try {
        while (received < expected) {
          if (isCancelled()) throw StateError('cancelled');
          await Future<void>.delayed(step);
          if (isCancelled()) throw StateError('cancelled');
          sink.add(List.filled(10, 1));
          received += 10;
          onProgress?.call(received, expected);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return received;
    };

Future<void> waitFor(bool Function() condition, String label) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待超时：$label');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late DownloadStore store;
  late DownloadService service;

  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_pause_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
    store = DownloadStore();
    service = DownloadService(
      store: store,
      baseDir: Directory('${support.path}${Platform.pathSeparator}downloads'),
      resolver: (e) async => const ResolvedMedia(url: 'http://x', expectedBytes: 100),
      downloader: stepDownloader(),
    );
  });

  test('排队中的任务可暂停，继续后完成', () async {
    service.enqueue(series(), [ep(1), ep(2)]);
    expect(service.pauseEpisode('s1-e2'), isTrue);
    expect(service.taskOf('s1-e2')!.state, DownloadState.paused);
    expect(service.hasActiveTasks, isTrue);

    await waitFor(() => service.taskOf('s1-e1')!.state == DownloadState.done,
        '第一集完成');
    expect(service.taskOf('s1-e2')!.state, DownloadState.paused);

    await service.resumeEpisode('s1-e2');
    await waitFor(() => service.taskOf('s1-e2')!.state == DownloadState.done,
        '第二集完成');
    expect(store.has('s1-e2'), isTrue);
  });

  test('下载中的任务暂停后保留进度，继续后完成', () async {
    service = DownloadService(
      store: store,
      baseDir: Directory('${support.path}${Platform.pathSeparator}downloads'),
      resolver: (e) async => const ResolvedMedia(url: 'http://x', expectedBytes: 200),
      downloader: stepDownloader(
          step: const Duration(milliseconds: 40), chunks: 20),
    );
    service.enqueue(series(), [ep(1)]);
    await waitFor(
        () => service.taskOf('s1-e1')!.state == DownloadState.running,
        '开始下载');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(service.pauseEpisode('s1-e1'), isTrue);
    await waitFor(
        () => service.taskOf('s1-e1')!.state == DownloadState.paused,
        '暂停生效');
    final paused = service.taskOf('s1-e1')!;
    expect(paused.received, lessThan(200));

    await service.resumeEpisode('s1-e1');
    await waitFor(() => service.taskOf('s1-e1')!.state == DownloadState.done,
        '继续后完成');
    expect(store.has('s1-e1'), isTrue);
    expect(File(store.entryOf('s1-e1')!.filePath).existsSync(), isTrue);
  });

  test('取消整部剧会清掉暂停任务', () async {
    service.enqueue(series(), [ep(1), ep(2)]);
    service.pauseEpisode('s1-e2');
    service.cancelSeries('s1');
    await waitFor(() => !service.hasActiveTasks, '任务全部结束');
    expect(service.taskOf('s1-e2')!.state, DownloadState.cancelled);
  });
}
