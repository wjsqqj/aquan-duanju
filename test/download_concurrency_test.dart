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

Future<void> waitFor(bool Function() condition, String label) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待超时：$label');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late DownloadStore store;

  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_concurrency_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
    store = DownloadStore();
  });

  DownloadService makeService({
    int concurrency = 1,
    int maxRetries = 0,
    required EpisodeDownloader downloader,
  }) =>
      DownloadService(
        store: store,
        baseDir: Directory('${support.path}${Platform.pathSeparator}downloads'),
        resolver: (_) async =>
            const ResolvedMedia(url: 'http://x', expectedBytes: 1),
        downloader: downloader,
        concurrency: concurrency,
        maxRetries: maxRetries,
        retryDelay: const Duration(milliseconds: 20),
      );

  test('同时下载数生效', () async {
    var running = 0;
    var maxRunning = 0;
    final service = makeService(
      concurrency: 2,
      downloader: (url, path, onProgress, isCancelled) async {
        running++;
        if (running > maxRunning) maxRunning = running;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        File(path).writeAsBytesSync([1]);
        running--;
        return 1;
      },
    );
    service.enqueue(series(), [ep(1), ep(2), ep(3), ep(4)]);
    await waitFor(
        () => store.seriesList.isNotEmpty &&
            store.episodesOf('s1').length == 4 &&
            !service.hasActiveTasks,
        '四集全部完成');
    expect(maxRunning, 2);
  });

  test('失败自动重试后成功', () async {
    var calls = 0;
    final service = makeService(
      maxRetries: 1,
      downloader: (url, path, onProgress, isCancelled) async {
        calls++;
        if (calls == 1) throw const HttpException('boom');
        File(path).writeAsBytesSync([1]);
        return 1;
      },
    );
    service.enqueue(series(), [ep(1)]);
    await waitFor(
        () => service.taskOf('s1-e1')!.state == DownloadState.done,
        '重试后完成');
    expect(calls, 2);
    expect(store.has('s1-e1'), isTrue);
  });

  test('重试次数耗尽后标记失败，可手动重试', () async {
    var calls = 0;
    final service = makeService(
      maxRetries: 1,
      downloader: (url, path, onProgress, isCancelled) async {
        calls++;
        throw const HttpException('always');
      },
    );
    service.enqueue(series(), [ep(1)]);
    await waitFor(
        () => service.taskOf('s1-e1')!.state == DownloadState.failed,
        '两次失败后标记');
    expect(calls, 2);
    expect(service.retryFailed('s1'), 1);
    await waitFor(
        () => service.taskOf('s1-e1')!.state == DownloadState.failed,
        '手动重试后仍失败');
    expect(calls, 4);
  });

  test('连续进度回调被节流，读值仍逐块更新且终态通知不丢', () async {
    const progressCount = 40;
    late DownloadService service;
    int? lastObservedReceived;
    service = makeService(
      downloader: (url, path, onProgress, isCancelled) async {
        // 同步连发 N 次进度：全部落在同一个 200ms 节流窗口内。
        for (var i = 1; i <= progressCount; i++) {
          onProgress?.call(i, progressCount);
        }
        // 完成态会把 received 收敛到实际文件大小，故在最后一次回调后立即读。
        lastObservedReceived = service.taskOf('s1-e1')?.received;
        File(path).writeAsBytesSync([1]);
        return 1;
      },
    );
    var notifications = 0;
    DownloadState? lastNotifiedState;
    service.addListener(() {
      notifications++;
      lastNotifiedState = service.taskOf('s1-e1')?.state;
    });
    service.enqueue(series(), [ep(1)]);
    // 等「通知里看到 done」而不是只看 task.state，确保终态通知真的到达。
    await waitFor(() => lastNotifiedState == DownloadState.done, '完成态通知');

    // 入队 / 开跑 / 进度 / 完成 / 收尾等固定通知约 6 次，远小于回调数 / 4。
    expect(notifications, lessThan(progressCount ~/ 4),
        reason: '进度通知必须按时间窗节流，不能逐 chunk 广播');
    final task = service.taskOf('s1-e1')!;
    expect(lastObservedReceived, progressCount, reason: 'received 仍逐块更新');
    expect(task.state, DownloadState.done);
  });
}
