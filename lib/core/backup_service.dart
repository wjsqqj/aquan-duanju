import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// 备份 / 恢复失败：消息可直接展示给用户。
class DataBackupException implements Exception {
  const DataBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份内的一条数据：原文 JSON 字符串 + 字节数 + SHA-256。
class DataBackupEntry {
  const DataBackupEntry({
    required this.name,
    required this.size,
    required this.sha256,
    required this.content,
  });

  final String name;
  final int size;
  final String sha256;

  /// 原文（JSON 字符串）。恢复时再 jsonDecode，保证校验与写入的是同一份字节。
  final String content;

  Map<String, dynamic> toJson() => {
    'size': size,
    'sha256': sha256,
    'content': content,
  };

  static DataBackupEntry fromJson(String name, Object? raw) {
    if (raw is! Map) {
      throw DataBackupException('$name 条目结构无效');
    }
    final size = raw['size'];
    final hash = raw['sha256'];
    final content = raw['content'];
    if (size is! int || hash is! String || content is! String) {
      throw DataBackupException('$name 条目字段缺失');
    }
    return DataBackupEntry(
      name: name,
      size: size,
      sha256: hash,
      content: content,
    );
  }
}

/// 一份完整备份（内存对象）。
class DataBackup {
  const DataBackup({
    required this.createdAt,
    required this.files,
    this.appVersion = '',
    this.version = DataBackupService.formatVersion,
  });

  final int version;
  final DateTime createdAt;
  final String appVersion;
  final Map<String, DataBackupEntry> files;

  Map<String, dynamic> toJson() => {
    'aquan_backup': version,
    'created_at': createdAt.toIso8601String(),
    'app_version': appVersion,
    'files': {for (final e in files.entries) e.key: e.value.toJson()},
  };
}

/// 恢复结果：已恢复条目与恢复前自动备份路径。
class RestoreResult {
  const RestoreResult({required this.restored, this.preRestorePath});

  final List<String> restored;
  final String? preRestorePath;
}

/// 数据备份与恢复服务。
///
/// 格式（v2）：单文件 JSON 信封，只存白名单数据文件的**原文** + 字节数 +
/// SHA-256；不含窗口状态、设备档案、下载文件、缓存或备份自身。
///
/// 安全 / 健壮性：
/// - 白名单 + 体积上限（单文件 10 MB / 总计 20 MB）；
/// - 读取时逐条校验 SHA-256 与字节数，任一条不合格整份拒绝；
/// - 恢复前自动把当前数据快照到 `<数据目录>/backups/`，失败时尽力回滚；
/// - 兼容 v1（history + follows 两份裸数据）。
class DataBackupService {
  static const int formatVersion = 2;
  static const int maxTotalBytes = 20 * 1024 * 1024;
  static const int maxEntryBytes = 10 * 1024 * 1024;
  static const int maxPreRestoreBackups = 10;
  static const int maxHistoryItems = 10000;
  static const int maxFollowItems = 5000;
  static const int maxSearchItems = 500;
  static const int maxPlaySkipItems = 500;

  static const List<String> allowedFiles = [
    'history',
    'follows',
    'searches',
    'play_skip',
    'settings',
  ];

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;

  DataBackupService({
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now;

  /// 生成备份对象（不写盘）。[allowInvalid] 用于「恢复前自动备份」：
  /// 当前数据不完整 / 结构异常时也尽量保留原文。
  Future<DataBackup> build(
    Map<String, Map<String, dynamic>> files, {
    String appVersion = '',
    bool allowInvalid = false,
  }) async {
    final entries = <String, DataBackupEntry>{};
    var total = 0;
    for (final file in files.entries) {
      final name = file.key;
      if (!allowedFiles.contains(name)) {
        if (allowInvalid) continue;
        throw DataBackupException('不允许备份的文件：$name');
      }
      if (!allowInvalid) _validateEntry(name, file.value);
      final content = jsonEncode(file.value);
      final bytes = utf8.encode(content);
      if (bytes.length > maxEntryBytes) {
        if (allowInvalid) continue;
        throw DataBackupException('$name 超过单文件备份上限');
      }
      total += bytes.length;
      if (total > maxTotalBytes) {
        if (allowInvalid) break;
        throw const DataBackupException('数据总大小超过备份上限');
      }
      entries[name] = DataBackupEntry(
        name: name,
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        content: content,
      );
    }
    if (entries.isEmpty && !allowInvalid) {
      throw const DataBackupException('没有可备份的数据');
    }
    return DataBackup(
      createdAt: _clock(),
      appVersion: appVersion,
      files: Map.unmodifiable(entries),
    );
  }

  /// 生成并写入目标文件；目标不能位于应用数据目录内。
  Future<void> exportTo(
    String targetPath,
    Map<String, Map<String, dynamic>> files, {
    String appVersion = '',
  }) async {
    final backup = await build(files, appVersion: appVersion);
    final dir = await _directory();
    final target = File(targetPath).absolute;
    final basePath = Directory(dir.path).absolute.path.toLowerCase();
    final prefix = basePath.endsWith(Platform.pathSeparator)
        ? basePath
        : '$basePath${Platform.pathSeparator}';
    final targetAbs = target.path.toLowerCase();
    if (targetAbs == basePath || targetAbs.startsWith(prefix)) {
      throw const DataBackupException('备份不能保存到应用数据目录内，请换一个位置');
    }
    final parent = target.parent;
    if (!await parent.exists()) {
      throw const DataBackupException('备份保存目录不存在');
    }
    final tmp = File('${target.path}.tmp');
    try {
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(backup.toJson()),
        flush: true,
      );
      await tmp.rename(target.path);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 读取并校验备份文件；任一条目不合格整份拒绝。
  Future<DataBackup> readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const DataBackupException('备份文件不存在');
    }
    final length = await file.length();
    if (length > maxTotalBytes) {
      throw const DataBackupException('备份文件超过 20 MB 上限');
    }
    final content = await file.readAsString();
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      throw const DataBackupException('备份文件不是有效 JSON');
    }
    if (decoded is! Map) {
      throw const DataBackupException('备份文件结构无效');
    }
    final raw = Map<String, dynamic>.from(decoded);
    final version = raw['aquan_backup'];
    if (version == 1) {
      return _readLegacyV1(raw);
    }
    if (version != formatVersion) {
      throw const DataBackupException('不是阿圈短剧的备份文件');
    }
    final rawFiles = raw['files'];
    if (rawFiles is! Map) {
      throw const DataBackupException('备份文件缺少数据条目');
    }
    final entries = <String, DataBackupEntry>{};
    var total = 0;
    for (final item in rawFiles.entries) {
      final name = item.key;
      if (name is! String || !allowedFiles.contains(name)) {
        throw DataBackupException('备份包含不允许的文件：$name');
      }
      final entry = DataBackupEntry.fromJson(name, item.value);
      final bytes = utf8.encode(entry.content);
      if (bytes.length != entry.size) {
        throw DataBackupException('$name 大小校验失败');
      }
      if (sha256.convert(bytes).toString() != entry.sha256) {
        throw DataBackupException('$name 校验失败，备份可能损坏');
      }
      if (entry.size > maxEntryBytes) {
        throw DataBackupException('$name 超过单文件上限');
      }
      total += entry.size;
      if (total > maxTotalBytes) {
        throw const DataBackupException('备份内容超过 20 MB 上限');
      }
      final data = jsonDecode(entry.content);
      if (data is! Map) throw DataBackupException('$name 不是 JSON 对象');
      _validateEntry(name, Map<String, dynamic>.from(data));
      entries[name] = entry;
    }
    if (entries.isEmpty) {
      throw const DataBackupException('备份不包含任何数据文件');
    }
    return DataBackup(
      createdAt:
          DateTime.tryParse(raw['created_at'] as String? ?? '') ?? _clock(),
      appVersion: raw['app_version'] as String? ?? '',
      files: Map.unmodifiable(entries),
    );
  }

  /// 恢复：先自动备份当前数据，再逐条 apply；失败时尽力回滚。
  Future<RestoreResult> restore(
    DataBackup backup, {
    required Future<void> Function(String name, Map<String, dynamic> data)
    apply,
    Map<String, Map<String, dynamic>> currentFiles = const {},
  }) async {
    final prePath = await _writePreRestore(currentFiles);
    final restored = <String>[];
    try {
      for (final entry in backup.files.values) {
        final decoded = jsonDecode(entry.content);
        if (decoded is! Map) {
          throw DataBackupException('${entry.name} 数据损坏');
        }
        await apply(entry.name, Map<String, dynamic>.from(decoded));
        restored.add(entry.name);
      }
    } catch (error) {
      for (final item in currentFiles.entries) {
        try {
          await apply(item.key, item.value);
        } catch (_) {}
      }
      throw DataBackupException(
        '恢复失败（$error），已尝试还原到恢复前状态。恢复前备份：${prePath ?? '(无)'}',
      );
    }
    await _prunePreRestore();
    return RestoreResult(restored: restored, preRestorePath: prePath);
  }

  Future<String?> _writePreRestore(
    Map<String, Map<String, dynamic>> currentFiles,
  ) async {
    try {
      final dir = await _directory();
      final backups = Directory('${dir.path}${Platform.pathSeparator}backups');
      if (!await backups.exists()) {
        await backups.create(recursive: true);
      }
      final backup = await build(currentFiles, allowInvalid: true);
      final stamp = _timestamp(_clock());
      final path =
          '${backups.path}${Platform.pathSeparator}pre-restore-$stamp.json';
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(backup.toJson()),
        flush: true,
      );
      return path;
    } catch (_) {
      // 恢复前备份失败不阻断恢复（但会在结果里显示「无」）。
      return null;
    }
  }

  Future<void> _prunePreRestore() async {
    try {
      final dir = await _directory();
      final backups = Directory('${dir.path}${Platform.pathSeparator}backups');
      if (!await backups.exists()) return;
      final files = <File>[];
      await for (final entity in backups.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('pre-restore-') && name.endsWith('.json')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      final remove = files.length - maxPreRestoreBackups;
      for (var i = 0; i < remove; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  DataBackup _readLegacyV1(Map<String, dynamic> raw) {
    final entries = <String, DataBackupEntry>{};
    for (final name in const ['history', 'follows']) {
      final value = raw[name];
      if (value is! Map) continue;
      final content = jsonEncode(Map<String, dynamic>.from(value));
      final bytes = utf8.encode(content);
      entries[name] = DataBackupEntry(
        name: name,
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        content: content,
      );
    }
    if (entries.isEmpty) {
      throw const DataBackupException('备份不包含任何数据文件');
    }
    return DataBackup(
      createdAt:
          DateTime.tryParse(raw['created_at'] as String? ?? '') ?? _clock(),
      appVersion: raw['app_version'] as String? ?? '',
      files: Map.unmodifiable(entries),
      version: 1,
    );
  }

  void _validateEntry(String name, Map<String, dynamic> data) {
    switch (name) {
      case 'history':
        _validateRecordMap(data, 'history', maxHistoryItems);
        break;
      case 'follows':
        _validateRecordMap(data, 'follows', maxFollowItems);
        break;
      case 'searches':
        final queries = data['queries'];
        if (queries is! List || queries.length > maxSearchItems) {
          throw const DataBackupException('搜索历史结构无效');
        }
        if (queries.any((q) => q is! String)) {
          throw const DataBackupException('搜索历史条目无效');
        }
        break;
      case 'play_skip':
        final items = data['items'];
        if (items is! Map || items.length > maxPlaySkipItems) {
          throw const DataBackupException('片头片尾偏好结构无效');
        }
        for (final value in items.values) {
          if (value is! Map) {
            throw const DataBackupException('片头片尾条目无效');
          }
          for (final key in const ['opening_ms', 'ending_ms']) {
            final v = value[key];
            if (v != null && (v is! num || v < 0 || v > 24 * 60 * 60 * 1000)) {
              throw const DataBackupException('片头片尾时间点无效');
            }
          }
        }
        break;
      case 'settings':
        if (data.length > 100) {
          throw const DataBackupException('设置项过多');
        }
        if (data.keys.any((key) => key.isEmpty)) {
          throw const DataBackupException('设置项名称无效');
        }
        break;
      default:
        throw DataBackupException('不允许的备份文件：$name');
    }
  }

  void _validateRecordMap(
    Map<String, dynamic> data,
    String name,
    int maxItems,
  ) {
    if (data.length > maxItems) {
      throw DataBackupException('$name 条数超过上限');
    }
    for (final entry in data.entries) {
      if (entry.key.isEmpty || entry.value is! Map) {
        throw DataBackupException('$name 条目无效');
      }
      final id = (entry.value as Map)['series_id'];
      if (id is! String || id.isEmpty) {
        throw DataBackupException('$name 条目缺少 series_id');
      }
    }
  }
}

String _timestamp(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  String three(int value) => value.toString().padLeft(3, '0');
  return '${utc.year}${two(utc.month)}${two(utc.day)}-'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}-'
      '${three(utc.millisecond)}';
}
