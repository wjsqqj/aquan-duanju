import 'dart:io';

import 'package:aquan_duanju/core/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

final List<int> _payload =
    List<int>.generate(100, (i) => i % 256);

Future<HttpServer> _serve({bool supportRange = true}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      final range = request.headers.value('range');
      var start = 0;
      if (supportRange && range != null && range.startsWith('bytes=')) {
        start = int.parse(range.substring(6).split('-').first);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('Content-Range',
            'bytes $start-${_payload.length - 1}/${_payload.length}');
      }
      final body = _payload.sublist(start);
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    } catch (_) {
      // 客户端取消时连接可能已关闭，测试里忽略。
    }
  });
  return server;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('aquan_downloader_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('HTTP Range 断点续传：从 .part 末尾继续', () async {
    final server = await _serve();
    addTearDown(() => server.close(force: true));
    final path = '${dir.path}${Platform.pathSeparator}f.mp4.part';
    File(path).writeAsBytesSync(_payload.sublist(0, 40));
    final progress = <List<int>>[];
    final size = await defaultDownloader(
      'http://127.0.0.1:${server.port}/f',
      path,
      (received, total) => progress.add([received, total]),
      () => false,
    );
    expect(size, 100);
    expect(File(path).readAsBytesSync(), _payload);
    expect(progress.last, [100, 100]);
  });

  test('服务端忽略 Range 时从头重下', () async {
    final server = await _serve(supportRange: false);
    addTearDown(() => server.close(force: true));
    final path = '${dir.path}${Platform.pathSeparator}f.mp4.part';
    File(path).writeAsBytesSync(_payload.sublist(0, 40));
    final size = await defaultDownloader(
      'http://127.0.0.1:${server.port}/f',
      path,
      null,
      () => false,
    );
    expect(size, 100);
    expect(File(path).readAsBytesSync(), _payload);
  });

  test('取消后保留已写入的 .part', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        request.response.contentLength = _payload.length;
        for (var i = 0; i < 10; i++) {
          request.response.add(_payload.sublist(i * 10, (i + 1) * 10));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await request.response.close();
      } catch (_) {
        // 客户端取消后连接关闭，忽略。
      }
    });
    addTearDown(() => server.close(force: true));
    final path = '${dir.path}${Platform.pathSeparator}f.mp4.part';
    var chunks = 0;
    await expectLater(
      defaultDownloader(
        'http://127.0.0.1:${server.port}/f',
        path,
        (received, total) => chunks++,
        () => chunks >= 2,
      ),
      throwsA(isA<StateError>()),
    );
    final part = File(path);
    expect(part.existsSync(), isTrue);
    expect(part.lengthSync(), greaterThan(0));
    expect(part.lengthSync(), lessThan(100));
  });
}
