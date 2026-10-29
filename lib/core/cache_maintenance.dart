import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 数据目录盘点结果（只读 stat，不读文件内容）。
class CacheInventory {
  const CacheInventory({
    this.userDataBytes = 0,
    this.downloadBytes = 0,
    this.orphanBytes = 0,
    this.orphanFiles = 0,
    this.directoryReadable = true,
  });

  /// 应用数据文件（历史 / 追剧 / 设置等）总字节。
  final int userDataBytes;

  /// 离线下载缓存总字节。
  final int downloadBytes;

  /// 可清理的孤儿临时文件总字节。
  final int orphanBytes;
  final int orphanFiles;

  final bool directoryReadable;

  int get totalBytes => userDataBytes + downloadBytes + orphanBytes;
}

class TempCleanupResult {
  const TempCleanupResult({this.deleted = 0, this.bytes = 0, this.failed = 0});

  final int deleted;
  final int bytes;
  final int failed;
}

/// 缓存盘点与孤儿文件清理。
///
/// 只处理「已核实的应用临时文件」：
/// - 数据目录顶层的 `*.tmp` / `*.tmp-*`（原子写残留）；
/// - 下载目录里的 `*.part`（中断的下载）。
/// 必须同时满足：普通文件、修改时间超过 [orphanAge]（默认 24h）。
/// 不读取、不修改、不移动任何用户数据文件。
class CacheMaintenance {
  CacheMaintenance({
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? downloadsDirectory,
    DateTime Function()? clock,
    this.orphanAge = const Duration(hours: 24),
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _downloadsDirectory =
           downloadsDirectory ??
           (() async {
             final dir = await getApplicationSupportDirectory();
             return Directory('${dir.path}${Platform.pathSeparator}downloads');
           }),
       _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function() _downloadsDirectory;
  final DateTime Function() _clock;
  final Duration orphanAge;

  Future<CacheInventory> inspect() async {
    final support = await _resolve(_supportDirectory);
    if (support == null) {
      return const CacheInventory(directoryReadable: false);
    }
    final now = _clock();
    var userBytes = 0;
    final orphans = <File>[];
    try {
      await for (final entity in support.list(followLinks: false)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        userBytes += stat.size;
        if (_isTempName(entity.path) &&
            stat.modified.isBefore(now.subtract(orphanAge))) {
          orphans.add(entity);
        }
      }
    } catch (_) {
      return CacheInventory(userDataBytes: userBytes, directoryReadable: false);
    }

    var downloadBytes = 0;
    final downloads = await _resolve(_downloadsDirectory);
    if (downloads != null) {
      try {
        await for (final entity in downloads.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          downloadBytes += stat.size;
          if (entity.path.toLowerCase().endsWith('.part') &&
              stat.modified.isBefore(now.subtract(orphanAge))) {
            orphans.add(entity);
          }
        }
      } catch (_) {
        // 下载目录不可读时忽略其盘点。
      }
    }

    var orphanBytes = 0;
    for (final file in orphans) {
      try {
        orphanBytes += await file.length();
      } catch (_) {}
    }
    return CacheInventory(
      userDataBytes: userBytes,
      downloadBytes: downloadBytes,
      orphanBytes: orphanBytes,
      orphanFiles: orphans.length,
    );
  }

  /// 删除孤儿临时文件；逐个执行，单个失败不中断。
  Future<TempCleanupResult> cleanOrphans() async {
    final support = await _resolve(_supportDirectory);
    if (support == null) return const TempCleanupResult(failed: 1);
    final now = _clock();
    final candidates = <File>[];
    try {
      await for (final entity in support.list(followLinks: false)) {
        if (entity is File && _isTempName(entity.path)) {
          candidates.add(entity);
        }
      }
    } catch (_) {
      return const TempCleanupResult(failed: 1);
    }
    final downloads = await _resolve(_downloadsDirectory);
    if (downloads != null) {
      try {
        await for (final entity in downloads.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && entity.path.toLowerCase().endsWith('.part')) {
            candidates.add(entity);
          }
        }
      } catch (_) {}
    }

    var deleted = 0;
    var bytes = 0;
    var failed = 0;
    for (final file in candidates) {
      try {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            !stat.modified.isBefore(now.subtract(orphanAge))) {
          continue;
        }
        bytes += stat.size;
        await file.delete();
        deleted++;
      } catch (_) {
        failed++;
      }
    }
    return TempCleanupResult(deleted: deleted, bytes: bytes, failed: failed);
  }

  Future<Directory?> _resolve(Future<Directory> Function() loader) async {
    try {
      final dir = await loader();
      if (!await dir.exists()) return null;
      return dir;
    } catch (_) {
      return null;
    }
  }

  static bool _isTempName(String path) {
    final name = path.split(Platform.pathSeparator).last.toLowerCase();
    return name.endsWith('.tmp') || name.contains('.tmp-');
  }
}
