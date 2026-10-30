import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 本地 HTTP 媒体服务：把本机文件以「token URL」的形式喂给电视。
///
/// 为什么需要：DLNA 电视只能拉 HTTP 直链，本地下载的剧集没有公网地址。
///
/// 实现要点（对齐 UPnPCast `LocalFileServer`）：
/// - 绑定 `anyIPv4`（不是 127.0.0.1，电视要访问）；
/// - 端口从 [defaultPort] 起逐个探测，避开被占用；
/// - URL 用一次性 token，**不暴露真实路径**；token 表按 LRU 淘汰；
/// - 支持 `Range`（拖动进度必须）、`HEAD`（部分电视先探长度）；
/// - 按扩展名推断 `Content-Type`（电视对 `application/octet-stream` 常常拒播）。
///
/// 这里没有用 `dart:io` 的 [HttpServer]：它在 HEAD 请求上会把
/// `Content-Length` 强制归零，而电视探测长度恰恰依赖这个头。改用
/// [ServerSocket] 手写响应，`Connection: close` 一请求一连接，简单可控。
class LocalMediaServer {
  LocalMediaServer({
    this.defaultPort = 18080,
    this.portAttempts = 20,
    this.hostOverride,
  });

  static const int maxEntries = 128;
  static const int _maxHeaderBytes = 16 * 1024;

  final int defaultPort;
  final int portAttempts;

  /// 测试注入点：跳过局域网地址探测（单测里拿不到私网地址）。
  final String? hostOverride;

  ServerSocket? _socket;
  final Map<String, String> _tokens = <String, String>{};
  final List<String> _order = <String>[];

  bool get running => _socket != null;

  int? get port => _socket?.port;

  /// 形如 `http://192.168.1.7:18080`；未启动时为 null。
  String? get baseUrl {
    final host = _localAddress;
    final server = _socket;
    if (host == null || server == null) return null;
    return 'http://$host:${server.port}';
  }

  String? _localAddress;

  /// 启动服务（幂等）。
  Future<bool> start() async {
    if (_socket != null) return true;
    final host = hostOverride ?? await _resolveLocalAddress();
    if (host == null) return false;
    for (var i = 0; i < portAttempts; i++) {
      final candidate = defaultPort + i;
      try {
        final socket = await ServerSocket.bind(InternetAddress.anyIPv4, candidate);
        socket.listen(_handleSocket, onError: (Object _) {});
        _socket = socket;
        _localAddress = host;
        return true;
      } on SocketException {
        continue;
      }
    }
    return false;
  }

  Future<void> stop() async {
    final socket = _socket;
    _socket = null;
    _localAddress = null;
    _tokens.clear();
    _order.clear();
    await socket?.close();
  }

  /// 把一个文件登记进服务，返回可直接投给电视的 URL。
  ///
  /// 服务未启动时自动启动；启动失败返回 null。
  Future<String?> urlFor(String filePath) async {
    if (!await start()) return null;
    final token = _register(filePath);
    final base = baseUrl;
    if (base == null) return null;
    return '$base/m/$token';
  }

  String _register(String filePath) {
    _order.remove(filePath);
    _order.insert(0, filePath);
    while (_order.length > maxEntries) {
      final dropped = _order.removeLast();
      _tokens.removeWhere((_, path) => path == dropped);
    }
    for (final entry in _tokens.entries) {
      if (entry.value == filePath) return entry.key;
    }
    final token = _newToken();
    _tokens[token] = filePath;
    return token;
  }

  static int _seq = 0;

  static String _newToken() {
    _seq++;
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$now${_seq.toRadixString(36)}';
  }

  Future<void> _handleSocket(Socket socket) async {
    final buffer = BytesBuilder(copy: true);
    try {
      await for (final chunk in socket) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final headerEnd = _indexOfHeaderEnd(bytes);
        if (headerEnd < 0) {
          if (bytes.length > _maxHeaderBytes) break;
          continue;
        }
        await _respond(socket, utf8.decode(bytes.sublist(0, headerEnd)));
        return;
      }
    } catch (_) {
      // 电视切集时会直接断连，属正常。
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  static int _indexOfHeaderEnd(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  Future<void> _respond(Socket socket, String header) async {
    final lines = header.split('\r\n');
    if (lines.isEmpty) return;
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) return;
    final method = requestLine[0].toUpperCase();
    final rawPath = requestLine[1];
    String? rangeHeader;
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'range') {
        rangeHeader = line.substring(idx + 1).trim();
      }
    }

    final path = Uri.tryParse(rawPath)?.path ?? '';
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != 'm') {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final filePath = _tokens[segments[1]];
    if (filePath == null) {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }

    final total = await file.length();
    final mime = mimeTypeForPath(filePath);
    final range = _parseRange(rangeHeader, total);
    final head = StringBuffer()
      ..write(range.partial ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: $mime\r\n')
      ..write('Content-Length: ${range.length}\r\n')
      ..write('Accept-Ranges: bytes\r\n');
    if (range.partial) {
      head.write('Content-Range: bytes ${range.start}-${range.end - 1}/$total\r\n');
    }
    head.write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(head.toString()));

    if (method == 'HEAD') {
      await socket.flush();
      return;
    }
    if (range.length > 0) {
      await socket.addStream(file.openRead(range.start, range.end));
    }
    await socket.flush();
  }

  static Future<void> _writeStatus(
    Socket socket,
    int code,
    String reason,
  ) async {
    socket.add(utf8.encode(
      'HTTP/1.1 $code $reason\r\n'
      'Content-Length: 0\r\n'
      'Connection: close\r\n\r\n',
    ));
    await socket.flush();
  }

  static _ByteRange _parseRange(String? header, int total) {
    if (header == null || !header.startsWith('bytes=')) {
      return _ByteRange(0, total, partial: false);
    }
    final spec = header.substring('bytes='.length);
    final dash = spec.indexOf('-');
    if (dash < 0) return _ByteRange(0, total, partial: false);
    final startText = spec.substring(0, dash).trim();
    final endText = spec.substring(dash + 1).trim();
    var start = int.tryParse(startText) ?? 0;
    var end = endText.isEmpty ? total : (int.tryParse(endText) ?? total) + 1;
    if (start < 0 || start >= total) start = 0;
    if (end > total) end = total;
    if (end <= start) end = total;
    return _ByteRange(start, end, partial: true);
  }

  static Future<String?> _resolveLocalAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (_isPrivate(address.address)) return address.address;
        }
      }
      for (final interface in interfaces) {
        if (interface.addresses.isNotEmpty) {
          return interface.addresses.first.address;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
}

class _ByteRange {
  const _ByteRange(this.start, this.end, {required this.partial});

  final int start;
  final int end;
  final bool partial;

  int get length => end - start < 0 ? 0 : end - start;
}

/// 扩展名 → MIME。电视对 `application/octet-stream` 常常直接拒播。
String mimeTypeForPath(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp4' || 'm4v' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'ts' => 'video/mp2t',
    'm3u8' => 'application/vnd.apple.mpegurl',
    'mov' => 'video/quicktime',
    'avi' => 'video/x-msvideo',
    'flv' => 'video/x-flv',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'wav' => 'audio/wav',
    'ogg' => 'audio/ogg',
    'srt' => 'application/x-subrip',
    'vtt' => 'text/vtt',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'application/octet-stream',
  };
}
