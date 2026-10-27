import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'ffi_bridge.dart';
import 'aqua_error.dart';

/// 阿圈短剧的数据客户端：包着 Go 核心的一个客户端句柄。
///
/// 所有调用都丢进后台 isolate（Go 侧是阻塞 FFI），UI isolate 永不等待；
/// retryable 的错误按 retryAfterMs 自动重试一次。
class AquaClient {
  AquaClient._(this._handle);

  final int _handle;

  /// 创建客户端并注册匿名设备档案。profilePath 指向设备档案 JSON（目录
  /// 不存在会创建）；通常传应用支持目录下的 aquan_device.json。
  static Future<AquaClient> create(
    String profilePath, {
    String configJson = '',
  }) async {
    final resp = await Isolate.run(
        () => AquaLibrary.open().create(profilePath, configJson));
    final env = _decodeEnvelope(resp);
    if (env.error != null) throw AquaException.fromJson(env.error!);
    return AquaClient._((env.result!['handle'] as num).toInt());
  }

  /// 调用一个 dispatch 方法。args 是方法参数数组，键大小写不敏感。
  Future<dynamic> call(String method, [List<Object?> args = const []]) async {
    final resp = await Isolate.run(() {
      final lib = AquaLibrary.open();
      var out = lib.call(_handle, method, jsonEncode(args));
      var env = _decodeEnvelope(out);
      // retryable 错误按服务端给的退避时间自动重试一次。
      if (env.error != null &&
          (env.error!['retryable'] as bool? ?? false)) {
        final wait = env.error!['retryAfterMs'] as int? ?? 500;
        final delay = wait.clamp(0, 5000);
        if (delay > 0) {
          // Isolate.run 里没有事件循环之外的同步 sleep，用 future 延时。
          return Future.delayed(Duration(milliseconds: delay), () {
            out = lib.call(_handle, method, jsonEncode(args));
            return _decodeEnvelope(out);
          }).then((env2) => env2);
        }
      }
      return Future.value(env);
    });
    if (resp.error != null) throw AquaException.fromJson(resp.error!);
    return resp.result;
  }

  /// 核心版本号（诊断用）。
  static String coreVersion() => AquaLibrary.open().version();
}

class _Envelope {
  _Envelope(this.result, this.error);

  final dynamic result;
  final Map<String, dynamic>? error;
}

_Envelope _decodeEnvelope(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw AquaException(
      code: AquaCode.unknown,
      message: '核心返回了无法解析的响应',
      retryable: false,
    );
  }
  final error = decoded['error'];
  if (error is Map<String, dynamic>) {
    return _Envelope(decoded['result'], error);
  }
  return _Envelope(decoded['result'], null);
}
