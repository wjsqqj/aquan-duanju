import 'dart:async';
import 'dart:io';

import 'update_mirrors.dart';

/// 直连（不经镜像）在探测结果里的固定 id。
const String kDirectProbeId = 'direct';

/// 一次连通性探测的结果：可连通的 id，按实测延迟升序。
class MirrorProbeResult {
  const MirrorProbeResult({
    this.reachableIds = const <String>[],
    this.latencyMs = const <String, int>{},
  });

  /// 快 → 慢。
  final List<String> reachableIds;
  final Map<String, int> latencyMs;

  bool get isEmpty => reachableIds.isEmpty;

  bool contains(String id) => reachableIds.contains(id);

  static const MirrorProbeResult empty = MirrorProbeResult();
}

/// 连通性测速：决定**先试哪个**。
///
/// 设备日常没有代理，GitHub 直连经常连不上；不做测速就只能先吃满一次直连超时
/// 再逐个试镜像。这里在检查/下载前并发测速（单个 4s 上界），把最快的排前面，
/// 直连也参与排序（`includeDirect`），因此"直连被墙"的机器第一个试的就是镜像。
///
/// 探测是纯优化：任何异常/空结果都只会退化成默认顺序，不允许阻断更新。
class UpdateMirrorProbe {
  UpdateMirrorProbe({
    List<UpdateMirror>? mirrors,
    HttpClient Function()? clientFactory,
    Future<bool> Function(String url)? ping,
    this.timeout = const Duration(seconds: 4),
    this.cacheTtl = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : mirrors = mirrors ?? builtInUpdateMirrors,
       _clientFactory = clientFactory ?? (() => HttpClient()),
       _pingOverride = ping,
       _clock = clock ?? DateTime.now;

  final List<UpdateMirror> mirrors;
  final Duration timeout;
  final Duration cacheTtl;

  final HttpClient Function() _clientFactory;

  /// 测试注入点：替换真实 HTTP 探测。
  final Future<bool> Function(String url)? _pingOverride;
  final DateTime Function() _clock;

  /// 按探测地址缓存（清单地址与资产地址是两条，各自独立）。
  final Map<String, _ProbeCacheEntry> _cache = <String, _ProbeCacheEntry>{};
  final Map<String, Future<MirrorProbeResult>> _inFlight =
      <String, Future<MirrorProbeResult>>{};

  /// 上次结果的同步快照（TTL 内有效）：需要"不再等探测"时用。
  MirrorProbeResult? cached(String probeUrl, {bool includeDirect = false}) {
    final entry = _cache[_cacheKey(probeUrl, includeDirect)];
    if (entry == null) return null;
    if (_clock().difference(entry.at) >= cacheTtl) return null;
    return entry.result;
  }

  static String _cacheKey(String probeUrl, bool includeDirect) =>
      includeDirect ? '$kDirectProbeId|$probeUrl' : probeUrl;

  /// 测速 [probeUrl]：直连（可选）与所有能改写该地址的镜像。
  Future<MirrorProbeResult> probe(
    String probeUrl, {
    bool includeDirect = false,
  }) async {
    final cacheKey = _cacheKey(probeUrl, includeDirect);
    final cachedEntry = _cache[cacheKey];
    if (cachedEntry != null &&
        _clock().difference(cachedEntry.at) < cacheTtl) {
      return cachedEntry.result;
    }
    final running = _inFlight[cacheKey];
    if (running != null) return running;

    // 探测永不向调用方抛：它是纯优化手段，失败只能退化为默认顺序。
    final future = _run(probeUrl, includeDirect).catchError(
      (Object _) => MirrorProbeResult.empty,
    );
    _inFlight[cacheKey] = future;
    try {
      final result = await future;
      // 全灭不写缓存：多半是本机网络抖动，下次重新测，别锁死 10 分钟。
      if (!result.isEmpty) {
        _cache[cacheKey] = _ProbeCacheEntry(_clock(), result);
      }
      return result;
    } finally {
      _inFlight.remove(cacheKey);
    }
  }

  void invalidate() {
    _cache.clear();
  }

  Future<MirrorProbeResult> _run(String probeUrl, bool includeDirect) async {
    final targets = <(String, String)>[
      if (includeDirect) (kDirectProbeId, probeUrl),
    ];
    for (final mirror in mirrors) {
      final resolved = mirror.resolve(probeUrl);
      if (resolved == null) continue;
      targets.add((mirror.id, resolved));
    }
    if (targets.isEmpty) return MirrorProbeResult.empty;

    final ping = _pingOverride ?? _ping;
    final samples = await Future.wait(
      targets.map((target) async {
        final stopwatch = Stopwatch()..start();
        final ok = await ping(target.$2);
        stopwatch.stop();
        return (id: target.$1, ok: ok, ms: stopwatch.elapsedMilliseconds);
      }),
    );

    final reachable = samples.where((s) => s.ok).toList()
      ..sort((a, b) => a.ms.compareTo(b.ms));
    return MirrorProbeResult(
      reachableIds: [for (final s in reachable) s.id],
      latencyMs: {for (final s in reachable) s.id: s.ms},
    );
  }

  /// 只取 1 字节：探测不该消耗流量，也不该被 CDN 缓存成完整文件。
  Future<bool> _ping(String url) async {
    HttpClient? client;
    try {
      client = _clientFactory()
        ..connectionTimeout = timeout;
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(timeout);
      final ok =
          response.statusCode >= HttpStatus.ok &&
          response.statusCode < HttpStatus.multipleChoices;
      try {
        await response.drain<void>().timeout(const Duration(seconds: 2));
      } catch (_) {
        // 探测只要状态码，读不动就断开。
      }
      return ok;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }
}

class _ProbeCacheEntry {
  const _ProbeCacheEntry(this.at, this.result);

  final DateTime at;
  final MirrorProbeResult result;
}
