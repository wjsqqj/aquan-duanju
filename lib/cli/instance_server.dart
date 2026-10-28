import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'launch_command.dart';

/// 单实例与命令转交。
///
/// 主实例在本机回环地址监听一个随机端口，端口写进两处：
/// - 应用支持目录的 `aquan_instance.json`（第二个 App 实例读这里）；
/// - 固定路径 `<UserConfigDir>/aquan-duanju/instance.json`（aquan-cli 读这里，
///   CLI 不依赖 Flutter 插件，算不出 path_provider 的目录）。
///
/// 第二个实例（或 aquan-cli）连上端口、发一行 JSON 命令，然后收一行回包。
/// App 间转发的回包是 {"ok":true}；播放控制命令由处理器给出真实结果。
class SingleInstance {
  SingleInstance._(this._server, this._file, this._locatorFile);

  final ServerSocket _server;
  final File _file;
  final File? _locatorFile;

  /// aquan-cli 用的固定路径（跨平台与 Go 侧 os.UserConfigDir() 对齐）。
  static String? locatorDir() {
    try {
      if (Platform.isWindows) {
        final appdata = Platform.environment['APPDATA'];
        return appdata == null ? null : '$appdata\\aquan-duanju';
      }
      if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        return home == null ? null : '$home/Library/Application Support/aquan-duanju';
      }
      if (Platform.isLinux) {
        final home = Platform.environment['HOME'];
        if (home == null) return null;
        final base =
            Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
        return '$base/aquan-duanju';
      }
    } catch (_) {}
    return null;
  }

  /// 已有实例在跑就转发命令并返回回包；返回 null 表示没有在跑的实例。
  static Future<Map<String, dynamic>?> forward(
    File file,
    LaunchCommand command,
  ) async {
    if (command.isEmpty) return null;
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final info = jsonDecode(raw);
      if (info is! Map<String, dynamic>) return null;
      final port = (info['port'] as num?)?.toInt();
      if (port == null || port <= 0) return null;
      return await _exchange(port, command.toJson());
    } catch (_) {
      // 端口文件过期（进程已退出）或对方还没准备好：当作没有实例。
      return null;
    }
  }

  /// 与主实例通信：发一行 JSON，收一行 JSON 回包。
  static Future<Map<String, dynamic>?> _exchange(
    int port,
    Map<String, dynamic> payload,
  ) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(milliseconds: 800),
    );
    try {
      socket.write(jsonEncode(payload));
      await socket.flush();
      await socket.close();
      final reply = await socket
          .map(utf8.decode)
          .join()
          .timeout(const Duration(seconds: 3));
      final text = reply.trim();
      if (text.isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } finally {
      socket.destroy();
    }
  }

  /// 成为主实例：监听端口并写端口文件。回调的返回值作为回包发回。
  static Future<SingleInstance> listen(
    File file,
    Future<Map<String, dynamic>> Function(LaunchCommand command) onCommand, {
    String? locatorDir,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final locatorFile = locatorDir == null
        ? null
        : File('$locatorDir${Platform.pathSeparator}instance.json');
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'port': server.port,
        'pid': pid,
      }));
      if (locatorFile != null) {
        await locatorFile.parent.create(recursive: true);
        await locatorFile.writeAsString(jsonEncode({
          'port': server.port,
          'pid': pid,
          'updated_at': DateTime.now().toIso8601String(),
        }));
      }
    } catch (_) {
      // 端口文件写不进去不影响正常使用，只是少了转交/CLI 控制能力。
    }
    final instance = SingleInstance._(server, file, locatorFile);
    server.listen((socket) {
      final buffer = <int>[];
      socket.listen(
        buffer.addAll,
        onDone: () async {
          Map<String, dynamic> reply = {'ok': true};
          try {
            final text = utf8.decode(buffer).trim();
            if (text.isNotEmpty) {
              final json = jsonDecode(text);
              if (json is Map<String, dynamic>) {
                reply = await onCommand(LaunchCommand.fromJson(json));
              }
            }
          } catch (e) {
            reply = {'ok': false, 'error': e.toString()};
          }
          try {
            socket.write(jsonEncode(reply));
            await socket.flush();
          } catch (_) {}
          socket.close();
        },
        onError: (_) => socket.close(),
      );
    });
    return instance;
  }

  Future<void> dispose() async {
    try {
      await _server.close();
    } catch (_) {}
    for (final f in [_file, if (_locatorFile != null) _locatorFile]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
