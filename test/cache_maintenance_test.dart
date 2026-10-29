import 'dart:io';

import 'package:aquan_duanju/core/cache_maintenance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory support;
  late Directory downloads;

  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_cache_support');
    downloads = Directory('${support.path}${Platform.pathSeparator}downloads')
      ..createSync(recursive: true);
  });

  tearDown(() {
    support.deleteSync(recursive: true);
  });

  CacheMaintenance service() => CacheMaintenance(
        supportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        clock: () => DateTime(2026, 10, 29, 12),
      );

  void oldFile(File file) {
    file.writeAsStringSync('x');
    file.setLastModifiedSync(DateTime(2026, 10, 27, 12));
  }

  test('盘点用户数据 / 下载缓存 / 孤儿文件', () async {
    File('${support.path}${Platform.pathSeparator}aquan_history.json')
        .writeAsStringSync('12345');
    final oldTmp = File('${support.path}${Platform.pathSeparator}a.json.tmp');
    oldFile(oldTmp);
    final freshTmp = File('${support.path}${Platform.pathSeparator}b.json.tmp');
    freshTmp.writeAsStringSync('x');
    final oldPart = File('${downloads.path}${Platform.pathSeparator}e1.part');
    oldFile(oldPart);
    final freshPart = File('${downloads.path}${Platform.pathSeparator}e2.part');
    freshPart.writeAsStringSync('xx');

    final inventory = await service().inspect();
    expect(inventory.directoryReadable, isTrue);
    expect(inventory.userDataBytes, greaterThanOrEqualTo(5));
    expect(inventory.downloadBytes, 3);
    expect(inventory.orphanFiles, 2);
    expect(inventory.orphanBytes, 2);
  });

  test('只清理超过 24 小时的临时文件', () async {
    final oldTmp = File('${support.path}${Platform.pathSeparator}a.json.tmp');
    oldFile(oldTmp);
    final freshTmp = File('${support.path}${Platform.pathSeparator}b.json.tmp');
    freshTmp.writeAsStringSync('x');
    final oldPart = File('${downloads.path}${Platform.pathSeparator}e1.part');
    oldFile(oldPart);

    final result = await service().cleanOrphans();
    expect(result.deleted, 2);
    expect(oldTmp.existsSync(), isFalse);
    expect(oldPart.existsSync(), isFalse);
    expect(freshTmp.existsSync(), isTrue);
  });

  test('目录不可读时返回失败而不是抛异常', () async {
    final result = await CacheMaintenance(
      supportDirectory: () async =>
          Directory('${support.path}${Platform.pathSeparator}missing'),
      downloadsDirectory: () async => downloads,
    ).cleanOrphans();
    expect(result.failed, 1);
  });
}
