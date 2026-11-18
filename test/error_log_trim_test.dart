import 'dart:io';

import 'package:aquan_duanju/core/error_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// 启动时的日志滚动策略：只截断、不丢最近的记录，且必须按整行切。
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aquan-logtrim');
    file = File('${dir.path}${Platform.pathSeparator}error_log.txt');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('小于阈值时不动', () async {
    await file.writeAsString('[1] 启动 · 正常\n\n[2] 播放 · 就绪\n\n');
    final before = await file.length();
    await trimLogFile(file, threshold: 1024, keep: 256);
    expect(await file.length(), before);
    expect(await file.readAsString(), contains('[1] 启动'));
  });

  test('超过阈值时截断到最近 keep，并从整行开始', () async {
    final buffer = StringBuffer();
    for (var i = 0; i < 3000; i++) {
      buffer.writeln('[$i] ${'弹幕' * 20}');
    }
    await file.writeAsString(buffer.toString());
    final before = await file.length();
    expect(before, greaterThan(64 * 1024));

    await trimLogFile(file, threshold: 64 * 1024, keep: 16 * 1024);

    final after = await file.length();
    expect(after, lessThan(before));
    expect(after, lessThanOrEqualTo(16 * 1024));

    final text = await file.readAsString();
    // 从完整的一行开始（不是半个字符/半行）。
    expect(RegExp(r'^\[\d+\] ').hasMatch(text), isTrue,
        reason: '截断必须对齐到行首');
    // 最旧的记录被丢掉，最新的保留。
    expect(text.contains('[0] '), isFalse);
    expect(text.contains('[2999] '), isTrue);
  });

  test('文件不存在时不报错', () async {
    await trimLogFile(File('${dir.path}${Platform.pathSeparator}nope.txt'),
        threshold: 1, keep: 1);
  });
}
