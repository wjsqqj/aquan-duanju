import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> historyEntry(String id) => {
      'series_id': id,
      'title': '剧$id',
      'updated_at': DateTime(2026, 10, 29).toIso8601String(),
    };

Map<String, Map<String, dynamic>> sampleFiles() => {
      'history': {'s1': historyEntry('s1')},
      'follows': {
        's1': {
          'series_id': 's1',
          'title': '剧1',
          'episode_count': 10,
          'latest_episode_count': 10,
          'state': 'watching',
          'updated_at': DateTime(2026, 10, 29).toIso8601String(),
        }
      },
      'searches': {
        'queries': ['测试', '短剧']
      },
      'play_skip': {
        'items': {
          's1': {'opening_ms': 15000, 'ending_ms': 30000, 'updated_at': 1}
        }
      },
      'settings': {'theme.mode': 'dark', 'history.limit': 100},
    };

void main() {
  late Directory support;
  late Directory output;

  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_backup_support');
    output = Directory.systemTemp.createTempSync('aquan_backup_output');
  });

  tearDown(() {
    support.deleteSync(recursive: true);
    output.deleteSync(recursive: true);
  });

  DataBackupService service() =>
      DataBackupService(directory: () async => support);

  test('构建 / 导出 / 读取 往返', () async {
    final s = service();
    final path = '${output.path}${Platform.pathSeparator}backup.json';
    await s.exportTo(path, sampleFiles(), appVersion: '1.0.0+11');
    final backup = await s.readFile(path);
    expect(backup.files.length, 5);
    expect(backup.appVersion, '1.0.0+11');
    final decoded = jsonDecode(backup.files['history']!.content);
    expect(decoded['s1']['series_id'], 's1');
  });

  test('篡改内容后校验失败', () async {
    final s = service();
    final path = '${output.path}${Platform.pathSeparator}backup.json';
    await s.exportTo(path, sampleFiles());
    final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final files = raw['files'] as Map<String, dynamic>;
    final history = files['history'] as Map<String, dynamic>;
    history['content'] = '${history['content']} ';
    File(path).writeAsStringSync(jsonEncode(raw));
    await expectLater(
      s.readFile(path),
      throwsA(isA<DataBackupException>()),
    );
  });

  test('v1 旧备份兼容（history + follows）', () async {
    final path = '${output.path}${Platform.pathSeparator}v1.json';
    File(path).writeAsStringSync(jsonEncode({
      'aquan_backup': 1,
      'history': {'s1': historyEntry('s1')},
      'follows': {
        's1': {
          'series_id': 's1',
          'title': '剧1',
          'updated_at': DateTime(2026).toIso8601String(),
        }
      },
    }));
    final backup = await service().readFile(path);
    expect(backup.version, 1);
    expect(backup.files.keys.toSet(), {'history', 'follows'});
  });

  test('恢复前自动快照，恢复按条目 apply', () async {
    final s = service();
    final path = '${output.path}${Platform.pathSeparator}backup.json';
    await s.exportTo(path, sampleFiles());
    final backup = await s.readFile(path);
    final applied = <String, Map<String, dynamic>>{};
    final result = await s.restore(
      backup,
      currentFiles: sampleFiles(),
      apply: (name, data) async => applied[name] = data,
    );
    expect(result.restored.length, 5);
    expect(applied.keys.toSet(), sampleFiles().keys.toSet());
    expect(result.preRestorePath, isNotNull);
    expect(File(result.preRestorePath!).existsSync(), isTrue);
    expect(
      Directory('${support.path}${Platform.pathSeparator}backups').existsSync(),
      isTrue,
    );
  });

  test('不允许导出到应用数据目录内', () async {
    final s = service();
    await expectLater(
      s.exportTo(
          '${support.path}${Platform.pathSeparator}backup.json', sampleFiles()),
      throwsA(isA<DataBackupException>()),
    );
  });

  test('结构非法时拒绝', () async {
    final s = service();
    await expectLater(
      s.build({
        'history': {
          'bad': {'title': '缺少 series_id'}
        }
      }),
      throwsA(isA<DataBackupException>()),
    );
  });
}
