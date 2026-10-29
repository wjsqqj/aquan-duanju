import 'dart:async';

import 'package:http/http.dart' as http;

import 'source_adapter.dart';
import 'source_import.dart';

/// 主动测速：对源接口发真实请求并计时（「连接成功 840ms」的数据来源）。
///
/// 对接口本身探测（而非 ping 域名）才能筛出「域名活着但接口已死」的假活源；
/// App 是原生环境，没有浏览器 CORS 限制，测的是真实可播性。
enum ProbeState { ok, timeout, failed }

/// 单源测速结论。
class ProbeOutcome {
  const ProbeOutcome({
    required this.sourceId,
    required this.state,
    this.latencyMs,
    this.reason = '',
  });

  final String sourceId;
  final ProbeState state;
  final int? latencyMs;
  final String reason;

  bool get isOk => state == ProbeState.ok;
}

/// 展示分级：<500 绿（快）/ <2000 正常 / 其余偏慢。zoo.ink 网页测速同阈值。
enum ProbeLevel { fast, normal, slow }

ProbeLevel probeLevel(int latencyMs) =>
    latencyMs < 500 ? ProbeLevel.fast : latencyMs < 2000 ? ProbeLevel.normal : ProbeLevel.slow;

/// 测速事件：每源完成即发（UI 边测边显示）。
sealed class ProbeEvent {
  const ProbeEvent();
}

class ProbeProgress extends ProbeEvent {
  const ProbeProgress(this.outcome, this.done, this.total);
  final ProbeOutcome outcome;
  final int done;
  final int total;
}

class ProbeFinished extends ProbeEvent {
  const ProbeFinished(this.outcomes);
  final List<ProbeOutcome> outcomes;
}

/// 探测 URL：JSON 源探 `{api}?ac=videolist&pg=1`，XML 源探 api 本身；
/// spider 源没有直连接口，探测配置 URL 无意义，直接返回 failed。
String probeUrlFor(SourceConfig config) {
  final api = config.api;
  if (config.kind == SourceKind.cmsJson &&
      !api.contains('ac=')) {
    return api.contains('?') ? '$api&ac=videolist&pg=1' : '$api?ac=videolist&pg=1';
  }
  return api;
}

/// 测速单个源：GET 计时到小响应完成；非 2xx 视为失败。
Future<ProbeOutcome> probeSource(
  SourceConfig config, {
  Duration timeout = const Duration(seconds: 8),
  http.Client? client,
}) async {
  if (config.kind == SourceKind.spider) {
    return ProbeOutcome(
        sourceId: config.id, state: ProbeState.failed, reason: '需要爬虫引擎');
  }
  final url = probeUrlFor(config);
  final own = client ?? http.Client();
  try {
    final sw = Stopwatch()..start();
    final res = await own
        .get(Uri.parse(url), headers: {
          if (config.headers['User-Agent'] == null)
            'User-Agent': SourceImporter.defaultUa,
          ...config.headers,
        })
        .timeout(timeout);
    sw.stop();
    if (res.statusCode >= 200 && res.statusCode < 400) {
      return ProbeOutcome(
          sourceId: config.id, state: ProbeState.ok, latencyMs: sw.elapsedMilliseconds);
    }
    return ProbeOutcome(
        sourceId: config.id,
        state: ProbeState.failed,
        latencyMs: sw.elapsedMilliseconds,
        reason: 'HTTP ${res.statusCode}');
  } on TimeoutException {
    return ProbeOutcome(sourceId: config.id, state: ProbeState.timeout);
  } catch (e) {
    return ProbeOutcome(
        sourceId: config.id, state: ProbeState.failed, reason: e.toString());
  } finally {
    if (client == null) own.close();
  }
}

/// 批量测速：并发 [concurrency]，每源完成即发 [ProbeProgress]，全部完成后发
/// [ProbeFinished]（按 成功→超时→失败、延迟升序 排好）。「扫描中」可经
/// [CancelToken] 中止（未测的源跳过，返回空列表）。
Stream<ProbeEvent> probeSources(
  List<SourceConfig> configs, {
  int concurrency = 6,
  Duration? timeout,
  CancelToken? cancel,
  http.Client? client,
}) async* {
  final outcomes = <ProbeOutcome>[];
  final total = configs.length;
  var next = 0;
  var done = 0;

  final progress = StreamController<ProbeOutcome>();
  Future<void> worker() async {
    while (true) {
      if (cancel?.isCancelled ?? false) return;
      final i = next++;
      if (i >= configs.length) return;
      final outcome = await probeSource(configs[i],
          timeout: timeout ?? const Duration(seconds: 8), client: client);
      outcomes.add(outcome);
      done++;
      progress.add(outcome);
    }
  }

  final workers = <Future<void>>[];
  final workerCount = total == 0 ? 0 : concurrency.clamp(1, total);
  for (var i = 0; i < workerCount; i++) {
    workers.add(worker());
  }
  final all = Future.wait(workers);

  // 由 worker 全部结束时关闭控制器（不依赖下面的 await-for 先退出，
  // 否则 0 候选时互相等待造成死锁）。
  unawaited(all.whenComplete(() {
    if (!progress.isClosed) progress.close();
  }));

  var received = 0;
  await for (final outcome in progress.stream) {
    received++;
    yield ProbeProgress(outcome, done, total);
    if (received >= total) break;
  }
  await all;
  if (!progress.isClosed) await progress.close();
  if (cancel?.isCancelled ?? false) {
    yield ProbeFinished(const []);
    return;
  }
  int stateRank(ProbeState s) =>
      s == ProbeState.ok ? 0 : s == ProbeState.timeout ? 1 : 2;
  outcomes.sort((a, b) {
    final aMs = a.latencyMs ?? 1 << 30;
    final bMs = b.latencyMs ?? 1 << 30;
    final byRank = stateRank(a.state).compareTo(stateRank(b.state));
    return byRank != 0 ? byRank : aMs.compareTo(bMs);
  });
  yield ProbeFinished(outcomes);
}
