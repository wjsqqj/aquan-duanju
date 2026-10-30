import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// 本地导入字体的注册器。
///
/// 字体文件不复制到应用目录（用户可能自己管理），而是记录绝对路径 +
/// 由路径哈希得到的稳定 family 名；启动时把设置里出现过的路径重新注册一遍，
/// 这样重启后仍是同一套字体。
class ReaderFontRegistrar {
  ReaderFontRegistrar._();

  static final Set<String> _registered = <String>{};

  /// 路径 → family，稳定且与文件名无关（同名不同目录不会串）。
  static String familyFor(String path) {
    final digest = sha1.convert(path.codeUnits);
    return 'ReaderLocal_${digest.toString().substring(0, 12)}';
  }

  /// 注册一个字体文件；重复调用是幂等的，失败返回 null。
  static Future<String?> register(String path) async {
    final family = familyFor(path);
    if (_registered.contains(family)) return family;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final data = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      final loader = FontLoader(family)..addFont(Future<ByteData>.value(data));
      await loader.load();
      _registered.add(family);
      return family;
    } catch (_) {
      return null;
    }
  }

  /// 启动时批量注册（忽略失败：字体没了就回退系统字体）。
  static Future<void> ensureRegistered(Iterable<String?> paths) async {
    for (final path in paths) {
      if (path == null || path.isEmpty) continue;
      await register(path);
    }
  }
}
