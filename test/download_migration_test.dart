import 'dart:io';

import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadService makeService(DownloadStore store, Directory baseDir) =>
    DownloadService(
      store: store,
      baseDir: baseDir,
      resolver: (episode) async => const ResolvedMedia(url: 'u'),
      downloader: (url, path, onProgress, isCancelled) async => 0,
    );

DownloadEntry entry(String episodeId, String path) => DownloadEntry(
      seriesId: 's1',
      seriesTitle: '剧',
      coverUrl: '',
      episodeId: episodeId,
      number: 1,
      title: '第1集',
      filePath: path,
      sizeBytes: 3,
      keyHex: '',
      quality: '720p',
      downloadedAt: DateTime(2026, 10, 29),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late Directory oldDir;
  late DownloadStore store;

  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_migrate_test');
    oldDir = Directory('${support.path}${Platform.pathSeparator}downloads')
      ..createSync(recursive: true);
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

  test('迁移：复制校验后删除源文件并更新记录', () async {
    final seriesDir =
        Directory('${oldDir.path}${Platform.pathSeparator}s1')
          ..createSync(recursive: true);
    final source = File(
        '${seriesDir.path}${Platform.pathSeparator}第001集.mp4')
      ..writeAsBytesSync([1, 2, 3]);
    await store.record(entry('s1-e1', source.path));

    final target =
        Directory('${support.path}${Platform.pathSeparator}new_downloads');
    final service = makeService(store, oldDir);
    final result = await service.migrateDownloadsTo(target);

    expect(result.moved, 1);
    expect(result.failed, 0);
    expect(result.bytes, 3);
    expect(service.baseDir.path, target.path);
    expect(source.existsSync(), isFalse);
    final moved = store.entryOf('s1-e1')!;
    expect(moved.filePath.startsWith(target.path), isTrue);
    expect(File(moved.filePath).readAsBytesSync(), [1, 2, 3]);
  });

  test('仅切换：旧文件与旧记录保持原位置', () async {
    final source = File('${oldDir.path}${Platform.pathSeparator}s1.mp4')
      ..writeAsBytesSync([1]);
    await store.record(entry('s1-e1', source.path));
    final target =
        Directory('${support.path}${Platform.pathSeparator}another');
    final service = makeService(store, oldDir);
    await service.setBaseDir(target);
    expect(service.baseDir.path, target.path);
    expect(store.entryOf('s1-e1')!.filePath, source.path);
    expect(source.existsSync(), isTrue);
  });

  test('目标与当前目录相同时拒绝迁移', () async {
    final service = makeService(store, oldDir);
    await expectLater(
      service.migrateDownloadsTo(oldDir),
      throwsA(isA<StateError>()),
    );
  });

  test('不能把下载目录切到当前目录的子目录', () async {
    final service = makeService(store, oldDir);
    await expectLater(
      service.setBaseDir(
          Directory('${oldDir.path}${Platform.pathSeparator}sub')),
      throwsA(isA<StateError>()),
    );
  });

  test('更新单集路径只改目标条目', () async {
    await store.record(entry('s1-e1', '/old/a.mp4'));
    await store.record(entry('s1-e2', '/old/b.mp4'));
    await store.updateFilePath('s1-e1', '/new/a.mp4');
    expect(store.entryOf('s1-e1')!.filePath, '/new/a.mp4');
    expect(store.entryOf('s1-e2')!.filePath, '/old/b.mp4');
  });
}
