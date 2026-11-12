import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'update_mirrors.dart';

/// 直连（不经镜像）在探测结果里的固定 id。
const String kDirectProbeId = 'direct';

/// 单个源的测速样本。
class MirrorProbeSample {
  const MirrorProbeSample({
    required this.id,
    required this.reachable,
    required this.latencyMs,
    this.bytesPerSecond = 0,
  });

  final String id;
  final bool reachable;
  final int latencyMs;

  /// 实测吞吐；0 表示没有吞吐数据（测试注入/读取失败）。
  final int bytesPerSecond;
}

/// 一次探测的结果：可达的 id，按**实测吞吐**降序；吞吐拿不到时按延迟升序。
class MirrorProbeResult {
  const MirrorProbeResult({
    this.reachableIds = const <String>[],
    this.latencyMs = const <String, int>{},
    this.throughputBps = const <String, int>{},
  });

  /// 快 → 慢。
  final List<String> reachableIds;
  final Map<String, int> latencyMs;

  /// 实测吞吐（B/s）。探测注入（测试）没有这项。
  final Map<String, int> throughputBps;

  bool get isEmpty => reachableIds.isEmpty;

  bool contains(String id) => reachableIds.contains(id);

  static const MirrorProbeResult empty = MirrorProbeResult();
}

/// 连通性 + 吞吐测速：决定**先试哪个**，以及**先放弃哪个**。
///
/// 老实现只取 1 字节，测到的是延迟：低延迟但被限速的镜像会排在最前，
/// 下载时卡在几十 KB/s 一直不断流——这正是「1% 要几分钟」的根因。
/// 现在每个源并发读最多 [probeBytes]（默认 256KB），按实际吞吐排序；
/// 读不满也不影响判定（4s 上界内能收多少算多少）。
///
/// 探测仍是纯优化：
/// - 任何异常/空结果只退化成默认顺序，绝不阻断更新；
/// - 结果只用于排序，调用方不得因此丢弃源（真实失败只由健康冷却过滤）。
class UpdateMirrorProbe {
  UpdateMirrorProbe({
    List<UpdateMirror>? mirrors,
    HttpClient Function()? clientFactory,
    Future<bool> Function(String url)? ping,
    this.timeout = const Duration(seconds: 4),
    this.cacheTtl = const Duration(minutes: 10),
    this.probeBytes = 256 * 1024,
    DateTime Function()? clock,
  }) : mirrors = mirrors ?? builtInUpdateMirrors,
       _clientFactory = clientFactory ?? (() => HttpClient()),
       _pingOverride = ping,
       _clock = clock ?? DateTime.now;

  final List<UpdateMirror> mirrors;
  final Duration timeout;
  final Duration cacheTtl;

  /// 每个源最多读多少字节来估算吞吐（一次下载只探一次，开销可忽略）。
  final int probeBytes;

  final HttpClient Function() _clientFactory;

  /// 测试注入点：替换真实 HTTP 探测（此时吞吐未知，按延迟排序）。
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

    final ping = _pingOverride;
    final samples = await Future.wait(
      targets.map(
        (target) => ping == null
            ? _measure(target.$1, target.$2)
            : _measureWithPing(target.$1, target.$2, ping),
      ),
    );

    final reachable = orderSamples(samples);
    return MirrorProbeResult(
      reachableIds: [for (final s in reachable) s.id],
      latencyMs: {for (final s in reachable) s.id: s.latencyMs},
      throughputBps: {
        for (final s in reachable)
          if (s.bytesPerSecond > 0) s.id: s.bytesPerSecond,
      },
    );
  }

  /// 可达源排序：吞吐优先；没有吞吐数据（测试注入）时退回延迟。
  @visibleForTesting
  static List<MirrorProbeSample> orderSamples(
    List<MirrorProbeSample> samples,
  ) {
    final reachable = samples.where((s) => s.reachable).toList()
      ..sort((a, b) {
        final left = a.bytesPerSecond;
        final right = b.bytesPerSecond;
        if (left > 0 && right > 0 && left != right) {
          return right.compareTo(left);
        }
        if (left > 0 && right == 0) return -1;
        if (left == 0 && right > 0) return 1;
        return a.latencyMs.compareTo(b.latencyMs);
      });
    return reachable;
  }

  Future<MirrorProbeSample> _measureWithPing(
    String id,
    String url,
    Future<bool> Function(String url) ping,
  ) async {
    final stopwatch = Stopwatch()..start();
    final ok = await ping(url);
    stopwatch.stop();
    return MirrorProbeSample(
      id: id,
      reachable: ok,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  Future<MirrorProbeSample> _measure(String id, String url) async {
    final stopwatch = Stopwatch()..start();
    HttpClient? client;
    var bytes = 0;
    var ok = false;
    try {
      client = _clientFactory()..connectionTimeout = timeout;
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${math.max(probeBytes - 1, 0)}',
      );
      final response = await request.close().timeout(timeout);
      ok = response.statusCode >= HttpStatus.ok &&
          response.statusCode < HttpStatus.multipleChoices;
      if (ok) {
        // 整体截止时间：逐 chunk 的 timeout 挡不住"每 3 秒挤 1 字节"的源。
        final deadline = DateTime.now().add(timeout);
        try {
          await for (final chunk in response.timeout(timeout)) {
            bytes += chunk.length;
            if (bytes >= probeBytes || DateTime.now().isAfter(deadline)) {
              break;
            }
          }
        } catch (_) {
          // 读不满/超时都不算失败：已收字节足以估算吞吐。
        }
      } else {
        try {
          await response.drain<void>().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    } catch (_) {
      ok = false;
    } finally {
      client?.close(force: true);
      stopwatch.stop();
    }
    final ms = math.max(stopwatch.elapsedMilliseconds, 1);
    return MirrorProbeSample(
      id: id,
      reachable: ok,
      latencyMs: ms,
      bytesPerSecond: bytes > 0 ? (bytes * 1000 / ms).round() : 0,
    );
  }
}

class _ProbeCacheEntry {
  const _ProbeCacheEntry(this.at, this.result);

  final DateTime at;
  final MirrorProbeResult result;
}
