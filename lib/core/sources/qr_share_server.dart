import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 扫码导入配置：一次性局域网 HTTP 服务。
///
/// 交互（hongguoTV PhoneSearchServer 语义）：桌面生成
/// `http://<LAN-IP>:<port>/<token>` 二维码 → 手机浏览器打开 → 粘贴配置提交 →
/// 桌面回调导入。安全：仅 site-local 连接、token 提交成功即失效、TTL 5 分钟。
class QrShareServer {
  QrShareServer();

  HttpServer? _server;
  String? _token;
  Timer? _ttlTimer;
  DateTime _expiresAt = DateTime.now();
  bool _consumed = false;

  /// 提交回调：收到配置原文（一次会话最多触发一次）。
  void Function(String configText)? onSubmit;

  static const ttl = Duration(minutes: 5);

  /// 启动分享会话：返回二维码内容 URL。
  Future<String> start() async {
    await stop();
    _token = _randomToken();
    _consumed = false;
    _expiresAt = DateTime.now().add(ttl);
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen((req) async {
      try {
        await _handle(req);
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
    _ttlTimer?.cancel();
    _ttlTimer = Timer(ttl, () => stop());
    return 'http://${await lanIP()}:${server.port}/$_token';
  }

  Future<void> stop() async {
    _ttlTimer?.cancel();
    _ttlTimer = null;
    await _server?.close(force: true);
    _server = null;
    _token = null;
    _consumed = false;
  }

  Future<void> _handle(HttpRequest req) async {
    // 仅内网来源（防公网扫描）。
    final remote = req.connectionInfo?.remoteAddress;
    final localOnly = remote != null &&
        (remote.isLoopback ||
            (remote.type == InternetAddressType.IPv4 && _isSiteLocal(remote)));
    if (!localOnly) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final expired = DateTime.now().isAfter(_expiresAt);
    final pathOk = _token != null && req.uri.path == '/$_token';
    final submitOk = _token != null &&
        req.uri.path == '/$_token/submit' &&
        req.method == 'POST';

    if (expired || _consumed || (!pathOk && !submitOk)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    if (req.method == 'GET' && pathOk) {
      req.response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      req.response.write(_formHtml.replaceAll('__ACTION__', '/$_token/submit'));
      await req.response.close();
      return;
    }

    if (submitOk) {
      if (_consumed) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final body = await utf8.decoder.bind(req).join();
      final config = Uri.parse('?$body').queryParameters['config'] ?? '';
      if (config.trim().isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.write('配置内容为空');
        await req.response.close();
        return;
      }
      _consumed = true; // 一次性：提交即失效。
      // 回调在响应前同步触发：调用方（测试/UI）等待响应返回时结果已就绪。
      onSubmit?.call(config);
      req.response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      req.response.write(_okHtml);
      await req.response.close();
      // 响应完成后异步回收服务器（同步 close 会中止刚写完的响应）。
      unawaited(Future<void>(() async {
        await Future<void>.delayed(Duration.zero);
        await stop();
      }));
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  static bool _isSiteLocal(InternetAddress addr) {
    final ip = addr.address;
    return ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        ip.startsWith('169.254.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
  }

  /// 电视/手机可达的局域网 IP（偏好 192.168 > 10 > 172.16-31）。
  static Future<String> lanIP() async {
    String? prefer192;
    String? prefer10;
    String? prefer172;
    final ifaces = await NetworkInterface.list();
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        if (addr.isLoopback || addr.type != InternetAddressType.IPv4) continue;
        if (addr.isLinkLocal) continue;
        final ip = addr.address;
        if (!_isSiteLocal(addr)) continue;
        if (ip.startsWith('192.168.')) {
          prefer192 ??= ip;
        } else if (ip.startsWith('10.')) {
          prefer10 ??= ip;
        } else {
          prefer172 ??= ip;
        }
      }
    }
    return prefer192 ?? prefer10 ?? prefer172 ?? '127.0.0.1';
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  static const _formHtml = '''
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>导入配置到阿圈短剧</title></head>
<body style="font-family:sans-serif;max-width:560px;margin:24px auto;padding:0 12px">
<h3>导入配置到阿圈短剧</h3>
<p style="color:#666">粘贴 TVBox / MoonTV / 多仓 / Base64 / 「名称|地址」配置文本，提交后桌面端自动导入。</p>
<form method="post" action="__ACTION__">
<textarea name="config" rows="12" style="width:100%;box-sizing:border-box"
  placeholder="http://xxx/api.php/provide/vod 或完整 TVBox 配置 JSON"></textarea>
<p><button style="padding:10px 24px;font-size:16px">提交导入</button></p>
</form>
</body></html>''';

  static const _okHtml = '''
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>已提交</title></head>
<body style="font-family:sans-serif;text-align:center;margin-top:48px">
<h3>✅ 已提交到桌面端</h3><p>可以关闭本页面了。</p>
</body></html>''';
}
