import 'dart:async';

import 'package:meta/meta.dart';

import 'config_decoder.dart';
import 'source_adapter.dart';
import 'source_import.dart';
import 'source_probe.dart';

/// 源市场流水线（全自动抓源，仅用户手动触发）：
///
/// 逐索引站抓页面 → 正则提取候选配置地址（过滤资源误报）→ 并发下载配置 →
/// 解码解析（复用 [SourceImporter]/[ConfigDecoder]）→ 候选去重 → 批量测速 →
/// 按延迟排序产出。任何一步都不会写库——入库由用户在 UI 勾选后走注册表。
sealed class MarketScanEvent {
  const MarketScanEvent();
}

/// 单索引站开始抓取。
class MarketSiteStarted extends MarketScanEvent {
  const MarketSiteStarted(this.site);
  final MarketSite site;
}

/// 单索引站完成：[configCount] 下载并解码成功的配置数、[candidateCount] 候选源数。
class MarketSiteDone extends MarketScanEvent {
  const MarketSiteDone({
    required this.site,
    required this.configCount,
    required this.candidateCount,
    this.error = '',
  });
  final MarketSite site;
  final int configCount;
  final int candidateCount;
  final String error;

  bool get jsRendered => error == kJsRendered;
}

/// JS 渲染页的失败原因标记（UI 据此显示专门文案）。
const String kJsRendered = 'JS_RENDERED';

/// 单源测速进度。
class MarketProbeProgress extends MarketScanEvent {
  const MarketProbeProgress(this.candidate, this.outcome, this.done, this.total);
  final SourceCandidate candidate;
  final ProbeOutcome outcome;
  final int done;
  final int total;
}

/// 扫描完成：候选已测速并排序；[parses] 是各配置里的 jx 解析接口（type=1），
/// [lives] 是各配置里的直播清单（写入 LivesStore）。
class MarketScanDone extends MarketScanEvent {
  const MarketScanDone(this.results, {this.parses = const [], this.lives = const []});
  final List<MarketCandidateResult> results;
  final List<ParseApi> parses;
  final List<LiveConfig> lives;
}

/// 一条测速完成的候选源。
class MarketCandidateResult implements Comparable<MarketCandidateResult> {
  const MarketCandidateResult({required this.candidate, required this.outcome});
  final SourceCandidate candidate;
  final ProbeOutcome outcome;

  bool get isOk => outcome.isOk;
  int? get latencyMs => outcome.latencyMs;

  @override
  int compareTo(MarketCandidateResult other) {
    int rank(ProbeState s) =>
        s == ProbeState.ok ? 0 : s == ProbeState.timeout ? 1 : 2;
    final byRank = rank(outcome.state).compareTo(rank(other.outcome.state));
    if (byRank != 0) return byRank;
    return (latencyMs ?? 1 << 30).compareTo(other.latencyMs ?? 1 << 30);
  }
}

/// 扫描器。
class MarketScanner {
  /// 每站最多提取的配置地址数（防超大页面把扫描拖成马拉松）。
  static const int maxConfigUrlsPerSite = 60;
  static const int maxCandidates = 200;

  /// 配置下载并发数。
  static const int configConcurrency = 3;

  static final RegExp _urlPattern =
      RegExp(r'''https?://[^\s"'<>()\[\]{}\\]+''');
  static final RegExp _junkExtension = RegExp(
      r'\.(css|js|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|apk|txt|html?|htm)(\?|#|$)',
      caseSensitive: false);

  Stream<MarketScanEvent> scan(
    List<MarketSite> sites, {
    CancelToken? cancel,
    Duration fetchTimeout = const Duration(seconds: 10),
  }) {
    final controller = StreamController<MarketScanEvent>();
    unawaited(_run(controller, sites, cancel, fetchTimeout));
    return controller.stream;
  }

  Future<void> _run(
    StreamController<MarketScanEvent> controller,
    List<MarketSite> sites,
    CancelToken? cancel,
    Duration fetchTimeout,
  ) async {
    final candidates = <SourceCandidate>[];
    final parses = <ParseApi>[];
    final lives = <LiveConfig>[];
    final seenApis = <String>{};
    final seenParseUrls = <String>{};
    final seenLiveUrls = <String>{};

    for (final site in sites) {
      if (cancel?.isCancelled ?? false) break;
      controller.add(MarketSiteStarted(site));
      var configCount = 0;
      var candidateCount = 0;
      String error = '';
      try {
        final page = await SourceImporter.fetchConfigText(site.url,
            cancel: cancel, timeout: fetchTimeout);
        final urls = extractConfigUrls(page);
        if (urls.isEmpty) {
          error =
              page.contains('<script') ? kJsRendered : '未在页面中找到配置地址';
        }
        final progress = StreamController<_ConfigFetch>();
        var next = 0;
        Future<void> worker() async {
          while (true) {
            if (cancel?.isCancelled ?? false) return;
            final i = next++;
            if (i >= urls.length || candidates.length >= maxCandidates) return;
            final url = urls[i];
            try {
              final cfgText =
                  await SourceImporter.fetchConfigText(url, cancel: cancel);
              final cfg = ConfigDecoder.decode(cfgText);
              final extracted = SourceImporter.extractSites(cfg, sourceUrl: url);
              for (final p in SourceImporter.extractParses(cfg)) {
                if (seenParseUrls.add(p.url)) parses.add(p);
              }
              for (final l in extractLives(cfg, sourceUrl: url)) {
                if (seenLiveUrls.add(l.url)) lives.add(l);
              }
              progress.add(_ConfigFetch(ok: true, candidates: extracted));
            } on SourceException {
              progress.add(const _ConfigFetch(ok: false));
            } catch (_) {
              progress.add(const _ConfigFetch(ok: false));
            }
          }
        }

        final workers = <Future<void>>[];
        final workerCount =
            urls.isEmpty ? 0 : configConcurrency.clamp(1, urls.length);
        for (var i = 0; i < workerCount; i++) {
          workers.add(worker());
        }
        unawaited(Future.wait(workers).whenComplete(() {
          if (!progress.isClosed) progress.close();
        }));

        await for (final fetch in progress.stream) {
          if (!fetch.ok) continue;
          configCount++;
          for (final c in fetch.candidates) {
            final key =
                '${c.kind.name}|${c.api.endsWith('/') ? c.api.substring(0, c.api.length - 1) : c.api}';
            if (!seenApis.add(key)) continue;
            candidates.add(c);
            candidateCount++;
          }
        }
      } on SourceException catch (e) {
        error = e.detail.isEmpty ? e.code.name : e.detail;
      } catch (e) {
        error = e.toString();
      }
      controller.add(MarketSiteDone(
        site: site,
        configCount: configCount,
        candidateCount: candidateCount,
        error: error,
      ));
    }

    if (cancel?.isCancelled ?? false) {
      controller.add(const MarketScanDone([]));
      await controller.close();
      return;
    }
    // 候选测速：给每个候选挂一个临时 SourceConfig 以复用 probeSource。
    final probeList = candidates
        .map((c) => SourceConfig(
              id: 'market:${c.api}',
              name: c.name,
              apis: [c.api],
              kind: c.kind,
              headers: c.headers,
            ))
        .toList();
    final outcomeById = <String, ProbeOutcome>{};
    final byId = <String, SourceCandidate>{
      for (final c in candidates) 'market:${c.api}': c,
    };
    await for (final e in probeSources(probeList,
        concurrency: 6,
        timeout: const Duration(seconds: 8),
        cancel: cancel)) {
      if (e is ProbeProgress) {
        outcomeById[e.outcome.sourceId] = e.outcome;
        final candidate = byId[e.outcome.sourceId];
        if (candidate != null) {
          controller.add(MarketProbeProgress(
            candidate,
            e.outcome,
            e.done,
            e.total,
          ));
        }
      }
    }
    final results = [
      for (final c in candidates)
        if (outcomeById['market:${c.api}'] != null)
          MarketCandidateResult(
              candidate: c, outcome: outcomeById['market:${c.api}']!),
    ]..sort();
    controller.add(MarketScanDone(results, parses: parses, lives: lives));
    await controller.close();
  }

  /// 页面 → 候选配置地址：过滤资源误报与本站静态资源，保序去重。
  @visibleForTesting
  List<String> extractConfigUrls(String page) {
    final out = <String>[];
    final seen = <String>{};
    for (final match in _urlPattern.allMatches(page)) {
      if (out.length >= maxConfigUrlsPerSite) break;
      final raw = match.group(0)!;
      var url = raw;
      while (url.endsWith(',') || url.endsWith(';') || url.endsWith('=')) {
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) continue;
      if (_junkExtension.hasMatch(url)) continue;
      // 显然不是配置的：备案/统计类公共资源。
      if (url.contains('beian.') || url.contains('analytics')) continue;
      if (!seen.add(url)) continue;
      out.add(url);
    }
    return out;
  }
}

class _ConfigFetch {
  const _ConfigFetch({required this.ok, this.candidates = const []});
  final bool ok;
  final List<SourceCandidate> candidates;
}
