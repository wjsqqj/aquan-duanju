import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'launch_command.dart';

/// 单实例与命令转交。
///
/// 主实例在本机回环地址监听一个随机端口，端口写进应用支持目录的
/// `aquan_instance.json`。第二个实例（例如 AI 又发了一条 --series）连上端口、
/// 把命令发过去，然后自己退出；主实例收到命令后开播并置顶窗口。
class SingleInstance {
  SingleInstance._(this._server, this._file);

  final ServerSocket _server;
  final File _file;

  /// 已有实例在跑就转发命令并返回 true；否则返回 false。
  static Future<bool> forward(File file, LaunchCommand command) async {
    if (command.isEmpty) return false;
    try {
      if (!await file.exists()) return false;
      final raw = await file.readAsString();
      final info = jsonDecode(raw);
      if (info is! Map<String, dynamic>) return false;
      final port = (info['port'] as num?)?.toInt();
      if (port == null || port <= 0) return false;
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 600));
      socket.write(jsonEncode(command.toJson()));
      await socket.flush();
      await socket.close();
      return true;
    } catch (_) {
      // 端口文件过期（进程已退出）或对方还没准备好：当作没有实例。
      return false;
    }
  }

  /// 成为主实例：监听端口并写端口文件。回调在 UI isolate 里执行。
  static Future<SingleInstance> listen(
    File file,
    void Function(LaunchCommand command) onCommand,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'port': server.port,
        'pid': pid,
      }));
    } catch (_) {
      // 端口文件写不进去不影响正常使用，只是少了一次转交能力。
    }
    final instance = SingleInstance._(server, file);
    server.listen((socket) {
      final buffer = <int>[];
      socket.listen(
        buffer.addAll,
        onDone: () {
          try {
            final text = utf8.decode(buffer).trim();
            if (text.isNotEmpty) {
              final json = jsonDecode(text);
              if (json is Map<String, dynamic>) {
                onCommand(LaunchCommand.fromJson(json));
              }
            }
          } catch (_) {
            // 坏消息直接忽略，不影响主实例。
          }
          socket.write('{"ok":true}');
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
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}
