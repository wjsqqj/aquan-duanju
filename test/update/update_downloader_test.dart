import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aquan_duanju/update/update_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地 HTTP 服务器：可配置是否支持 Range，以及是否"低速不断流"。
class _TestServer {
  _TestServer._(this._server, this.payload, {required this.supportsRange});

  final HttpServer _server;
  final Uint8List payload;
  final bool supportsRange;

  int requests = 0;

  static Future<_TestServer> start(
    int size, {
    bool supportsRange = true,
    bool trickle = false,
  }) async {
    final payload = Uint8List.fromList(
      List<int>.generate(size, (i) => i % 251),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _TestServer._(
      server,
      payload,
      supportsRange: supportsRange,
    );
    server.listen((request) {
      instance.requests++;
      unawaited(instance._handle(request, trickle: trickle));
    });
    return instance;
  }

  String get url => 'http://127.0.0.1:${_server.port}/pkg.exe';

  Future<void> _handle(HttpRequest request, {required bool trickle}) async {
    final response = request.response;
    try {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = payload.length - 1;
      final isProbe = range == 'bytes=0-0';
      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (match != null) {
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) {
            end = math.min(int.parse(match.group(2)!), payload.length - 1);
          }
          if (isProbe) end = start;
        }
      }
      if (start >= payload.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${payload.length}',
        );
        await response.close();
        return;
      }

      final useRange = supportsRange && range != null;
      if (useRange) {
        end = math.min(end, payload.length - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
      } else {
        start = 0;
        end = payload.length - 1;
        response.statusCode = HttpStatus.ok;
      }
      response.headers.contentLength = end - start + 1;

      if (trickle && !isProbe) {
        // 低速但不断流：每 100ms 只发 512B（约 5KB/s）。
        for (var offset = start; offset <= end; offset += 512) {
          final stop = math.min(offset + 512, end + 1);
          response.add(payload.sublist(offset, stop));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } else {
        response.add(payload.sublist(start, end + 1));
      }
      await response.close();
    } catch (_) {
      // 客户端主动断开（看门狗/取消）会走到这里。
    }
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('update_downloader_test_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File targetFile() => File('${dir.path}${Platform.pathSeparator}update.exe');

  test('分片并发下载：结果与原文件一致，分片文件被清理', () async {
    const size = 5 * 1024 * 1024;
    final server = await _TestServer.start(size);
    addTearDown(server.close);

    final target = targetFile();
    final downloader = UpdateDownloader(
      maxConnections: 4,
      minSegmentBytes: 1024 * 1024,
      progressInterval: const Duration(milliseconds: 50),
    );
    final result = await downloader.download(
      sources: [UpdateDownloadSource(url: server.url, label: '测试源')],
      target: target,
    );

    expect(result.bytes, size);
    expect(await target.readAsBytes(), server.payload);
    expect(await File('${target.path}.part').exists(), isFalse);
    for (var i = 0; i < 4; i++) {
      expect(await File('${target.path}.part$i').exists(), isFalse);
    }
    expect(server.requests, greaterThan(1), reason: '应当是多连接分片');
  });

  test('服务端不支持 Range 时回退单连接', () async {
    const size = 512 * 1024;
    final server = await _TestServer.start(size, supportsRange: false);
    addTearDown(server.close);

    final target = targetFile();
    final downloader = UpdateDownloader(minSegmentBytes: 1024);
    await downloader.download(
      sources: [UpdateDownloadSource(url: server.url, label: '测试源')],
      target: target,
    );

    expect(await target.readAsBytes(), server.payload);
    expect(await File('${target.path}.part').exists(), isFalse);
  });

  test('低速看门狗：换到下一个源并续传，不从头再来', () async {
    const size = 512 * 1024;
    final slow = await _TestServer.start(size, trickle: true);
    final fast = await _TestServer.start(size);
    addTearDown(slow.close);
    addTearDown(fast.close);

    final target = targetFile();
    final downloader = UpdateDownloader(
      minSegmentBytes: 1024 * 1024, // 强制单连接，便于观察续传
      slowWindow: const Duration(milliseconds: 400),
      minSpeedBps: 20 * 1024,
      idleTimeout: const Duration(seconds: 2),
      progressInterval: const Duration(milliseconds: 100),
      probeTimeout: const Duration(milliseconds: 500),
    );

    final stopwatch = Stopwatch()..start();
    final result = await downloader.download(
      sources: [
        UpdateDownloadSource(url: slow.url, label: '慢源'),
        UpdateDownloadSource(url: fast.url, label: '快源'),
      ],
      target: target,
    );
    stopwatch.stop();

    expect(result.source.label, '快源');
    expect(await target.readAsBytes(), slow.payload);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('取消：抛 DownloadCancelled 且保留 .part 供续传', () async {
    const size = 512 * 1024;
    final server = await _TestServer.start(size, trickle: true);
    addTearDown(server.close);

    final target = targetFile();
    final downloader = UpdateDownloader(
      minSegmentBytes: 1024 * 1024,
      slowWindow: const Duration(seconds: 30),
      minSpeedBps: 0,
      progressInterval: const Duration(milliseconds: 100),
      probeTimeout: const Duration(milliseconds: 500),
    );

    final cancelAt = DateTime.now().add(const Duration(milliseconds: 500));
    await expectLater(
      downloader.download(
        sources: [UpdateDownloadSource(url: server.url, label: '慢源')],
        target: target,
        isCancelled: () => DateTime.now().isAfter(cancelAt),
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(await File('${target.path}.part').exists(), isTrue);
  });

  test('进度非递减且带总大小', () async {
    const size = 1024 * 1024;
    final server = await _TestServer.start(size);
    addTearDown(server.close);

    final progress = <DownloadProgress>[];
    final downloader = UpdateDownloader(
      progressInterval: const Duration(milliseconds: 50),
      minSegmentBytes: 256 * 1024,
    );
    await downloader.download(
      sources: [UpdateDownloadSource(url: server.url, label: '测试源')],
      target: targetFile(),
      onProgress: progress.add,
    );

    expect(progress, isNotEmpty);
    var last = -1;
    for (final item in progress) {
      expect(item.received, greaterThanOrEqualTo(last));
      last = item.received;
      expect(item.total, size);
      expect(item.fraction, isNotNull);
    }
  });

  test('校验失败删除坏包并换下一个源', () async {
    const size = 256 * 1024;
    final first = await _TestServer.start(size);
    final second = await _TestServer.start(size);
    addTearDown(first.close);
    addTearDown(second.close);

    final target = targetFile();
    var validated = 0;
    final downloader = UpdateDownloader(minSegmentBytes: 1024);
    final result = await downloader.download(
      sources: [
        UpdateDownloadSource(url: first.url, label: '源A'),
        UpdateDownloadSource(url: second.url, label: '源B'),
      ],
      target: target,
      validate: (file) async => ++validated > 1,
    );

    expect(result.source.label, '源B');
    expect(await target.readAsBytes(), second.payload);
  });

  test('所有源失败时抛 UpdateDownloadException', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });

    final downloader = UpdateDownloader();
    await expectLater(
      downloader.download(
        sources: [
          UpdateDownloadSource(
            url: 'http://127.0.0.1:${server.port}/missing.exe',
            label: '坏源',
          ),
        ],
        target: targetFile(),
      ),
      throwsA(isA<UpdateDownloadException>()),
    );
  });
}
