import 'dart:async';

import 'package:http/http.dart' as http;

import 'live_parser.dart';
import '../sources/source_adapter.dart';
import '../sources/source_probe.dart';

/// 直播频道测速（zyfun 语义）：`GET Range: bytes=0-1` 计时首包，并发 5。
class LiveProbe {
  LiveProbe._();

  static Future<ProbeOutcome> probeChannel(
    LiveChannel channel, {
    Duration timeout = const Duration(seconds: 6),
    http.Client? client,
  }) async {
    if (channel.urls.isEmpty) {
      return ProbeOutcome(sourceId: channel.name, state: ProbeState.failed, reason: '无地址');
    }
    final target = channel.urls[channel.activeIndex.clamp(0, channel.urls.length - 1)];
    final own = client ?? http.Client();
    try {
      final sw = Stopwatch()..start();
      final res = await own
          .get(Uri.parse(target.url),
              headers: {
                'Range': 'bytes=0-1',
                if (!target.headers.containsKey('User-Agent'))
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
                ...target.headers,
              })
          .timeout(timeout);
      sw.stop();
      if (res.statusCode >= 200 && res.statusCode < 400) {
        return ProbeOutcome(
            sourceId: channel.name, state: ProbeState.ok, latencyMs: sw.elapsedMilliseconds);
      }
      return ProbeOutcome(
          sourceId: channel.name,
          state: ProbeState.failed,
          latencyMs: sw.elapsedMilliseconds,
          reason: 'HTTP ${res.statusCode}');
    } on TimeoutException {
      return ProbeOutcome(sourceId: channel.name, state: ProbeState.timeout);
    } catch (e) {
      return ProbeOutcome(
          sourceId: channel.name, state: ProbeState.failed, reason: e.toString());
    } finally {
      if (client == null) own.close();
    }
  }

  /// 批量测速：并发 [concurrency]，每频道完成即发事件。
  static Stream<(LiveChannel, ProbeOutcome)> probeAll(
    List<LiveChannel> channels, {
    int concurrency = 5,
    Duration timeout = const Duration(seconds: 6),
    CancelToken? cancel,
  }) {
    final queue = StreamController<(LiveChannel, ProbeOutcome)>();
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (cancel?.isCancelled ?? false) return;
        final i = next++;
        if (i >= channels.length) return;
        final outcome = await probeChannel(channels[i], timeout: timeout);
        queue.add((channels[i], outcome));
      }
    }

    final workers = <Future<void>>[];
    final count = channels.isEmpty ? 0 : concurrency.clamp(1, channels.length);
    for (var i = 0; i < count; i++) {
      workers.add(worker());
    }
    unawaited(Future.wait(workers).whenComplete(() {
      if (!queue.isClosed) queue.close();
    }));
    return queue.stream;
  }
}
