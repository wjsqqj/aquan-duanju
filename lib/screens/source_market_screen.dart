import 'dart:async';

import 'package:flutter/material.dart';

import '../core/sources/source_adapter.dart';
import '../core/sources/source_import.dart';
import '../core/sources/source_market.dart';
import '../core/sources/source_probe.dart';
import '../widgets/common.dart';

/// 源市场：从索引站自动抓取可用源（带「连接成功 XXXms」测速），勾选后入库。
///
/// 合规边界：预置的只是「接口清单页」地址（可增删），内容源全部由扫描产生；
/// 扫描仅用户手动触发，无任何后台网络行为。
class SourceMarketScreen extends StatefulWidget {
  const SourceMarketScreen({super.key});

  @override
  State<SourceMarketScreen> createState() => _SourceMarketScreenState();
}

class _SourceMarketScreenState extends State<SourceMarketScreen> {
  final _scanner = MarketScanner();
  final _results = <MarketCandidateResult>[];
  final _selected = <String>{};
  final _siteStatus = <String, _SiteStatus>{};

  bool _scanning = false;
  bool _importing = false;
  StreamSubscription<MarketScanEvent>? _sub;
  CancelToken? _cancel;

  @override
  void dispose() {
    _cancel?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sites = scope.marketSites.sites;
    final theme = Theme.of(context);
    final okCount = _results.where((r) => r.isOk).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('源市场'),
        actions: [
          if (!_scanning)
            IconButton(
              tooltip: '添加索引站',
              icon: const Icon(Icons.add_link),
              onPressed: () => _addSiteDialog(scope),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: scope.settings.sourcesDisclaimerDismissed
                ? const SizedBox.shrink()
                : _DisclaimerBar(
                    onDismiss: () {
                      scope.settings.sourcesDisclaimerDismissed = true;
                      if (mounted) setState(() {});
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _scanning ? null : () => _scan(scope),
                  icon: Icon(_scanning ? Icons.hourglass_top : Icons.radar),
                  label: Text(_scanning ? '扫描中…' : '扫描索引站'),
                ),
                if (_scanning) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _cancel?.cancel(),
                    child: const Text('停止'),
                  ),
                ],
                const Spacer(),
                if (_results.isNotEmpty)
                  Text('$okCount/${_results.length} 可用',
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _SitesSection(
                  sites: sites,
                  scanning: _scanning,
                  status: _siteStatus,
                  onToggle: (site, v) async {
                    await scope.marketSites.setSiteEnabled(site.id, v);
                    if (mounted) setState(() {});
                  },
                  onRemove: (site) async {
                    await scope.marketSites.removeSite(site.id);
                    if (mounted) setState(() {});
                  },
                  onReset: () async {
                    await scope.marketSites.resetBuiltin();
                    if (mounted) setState(() {});
                  },
                ),
                if (_results.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Text('候选源（按延迟排序）',
                            style: theme.textTheme.titleSmall),
                        const Spacer(),
                        TextButton(
                          onPressed: _importing
                              ? null
                              : () => _importSelected(scope),
                          child: Text(
                              '入库所选（${_selected.length}）'),
                        ),
                      ],
                    ),
                  ),
                  for (final r in _results)
                    CheckboxListTile(
                      value: _selected.contains(r.candidate.api),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: Text(r.candidate.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(r.candidate.api,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      secondary: _LatencyChip(outcome: r.outcome),
                      onChanged: r.candidate.usable
                          ? (v) => setState(() {
                                if (v ?? false) {
                                  _selected.add(r.candidate.api);
                                } else {
                                  _selected.remove(r.candidate.api);
                                }
                              })
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _scan(AppScope scope) async {
    final sites = scope.marketSites.enabledSites;
    if (sites.isEmpty) {
      _snack('没有启用的索引站，请先添加');
      return;
    }
    _cancel?.cancel();
    final cancel = _cancel = CancelToken();
    setState(() {
      _scanning = true;
      _results.clear();
      _selected.clear();
      _siteStatus.clear();
    });
    _sub?.cancel();
    _sub = _scanner.scan(sites, cancel: cancel).listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case MarketSiteStarted():
            _siteStatus[event.site.id] = _SiteStatus('扫描中…');
          case MarketSiteDone():
            if (event.error == kJsRendered) {
              _siteStatus[event.site.id] = _SiteStatus(
                  '页面由脚本渲染，无法自动解析，请手动复制接口地址导入',
                  failed: true);
            } else if (event.error.isNotEmpty) {
              _siteStatus[event.site.id] =
                  _SiteStatus('失败：${event.error}', failed: true);
            } else {
              _siteStatus[event.site.id] = _SiteStatus(
                  '配置 ${event.configCount} 份 · 候选 ${event.candidateCount} 个');
            }
          case MarketProbeProgress():
            _results.removeWhere(
                (r) => r.candidate.api == event.candidate.api);
            _results.add(MarketCandidateResult(
                candidate: event.candidate, outcome: event.outcome));
            _results.sort();
          case MarketScanDone():
            _results
              ..clear()
              ..addAll(event.results);
            for (final r in event.results) {
              if (r.candidate.usable) _selected.add(r.candidate.api);
            }
            _scanning = false;
            // jx 解析接口随扫描一并登记（播放器在需要时轮询）。
            if (event.parses.isNotEmpty) {
              scope.marketSites.setParses(event.parses);
            }
            // lives 直播配置入库。
            if (event.lives.isNotEmpty) {
              scope.lives.addCandidates(event.lives);
            }
        }
      });
    }, onDone: () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _importSelected(AppScope scope) async {
    final selected = _results
        .where((r) => _selected.contains(r.candidate.api))
        .map((r) => r.candidate)
        .toList();
    if (selected.isEmpty) {
      _snack('先勾选要入库的源');
      return;
    }
    setState(() => _importing = true);
    final added = await scope.sources.addCandidates(selected);
    setState(() => _importing = false);
    _snack(added > 0 ? '已入库 $added 个源' : '所选源均已存在');
  }

  Future<void> _addSiteDialog(AppScope scope) async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加索引站'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                  labelText: '清单页地址（http/https）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final url = urlController.text.trim();
    final name = nameController.text.trim();
    if (!url.startsWith('http')) {
      _snack('地址必须是 http/https');
      return;
    }
    try {
      SourceImporter.validateImportUrl(url);
    } on SourceException catch (e) {
      _snack(e.friendlyText);
      return;
    }
    await scope.marketSites
        .addSite(name.isEmpty ? Uri.parse(url).host : name, url);
    if (mounted) setState(() {});
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }
}

class _SiteStatus {
  _SiteStatus(this.text, {this.failed = false});
  final String text;
  final bool failed;
}

/// 索引站列表区块。
class _SitesSection extends StatelessWidget {
  const _SitesSection({
    required this.sites,
    required this.scanning,
    required this.status,
    required this.onToggle,
    required this.onRemove,
    required this.onReset,
  });

  final List<MarketSite> sites;
  final bool scanning;
  final Map<String, _SiteStatus> status;
  final Future<void> Function(MarketSite, bool) onToggle;
  final Future<void> Function(MarketSite) onRemove;
  final Future<void> Function() onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Text('索引站（清单页，非内容源）',
                  style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton(
                onPressed: scanning ? null : onReset,
                child: const Text('恢复预置'),
              ),
            ],
          ),
        ),
        for (final site in sites)
          ListTile(
            dense: true,
            title: Text(site.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(site.url,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (status[site.id] != null)
                  Text(
                    status[site.id]!.text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: status[site.id]!.failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: site.enabled,
                  onChanged: scanning
                      ? null
                      : (v) => onToggle(site, v),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.close),
                  onPressed:
                      scanning ? null : () => onRemove(site),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「连接成功 XXXms」三态角标。
class _LatencyChip extends StatelessWidget {
  const _LatencyChip({required this.outcome});

  final ProbeOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (outcome.state) {
      ProbeState.ok => (() {
          final level = probeLevel(outcome.latencyMs ?? 9999);
          return (
            '连接成功 ${outcome.latencyMs}ms',
            switch (level) {
              ProbeLevel.fast => Colors.green,
              ProbeLevel.normal => Colors.orange,
              ProbeLevel.slow => Colors.red,
            }
          );
        })(),
      ProbeState.timeout => ('超时', Colors.grey),
      ProbeState.failed => ('失败', theme.colorScheme.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }
}

/// 免责提示条：内容由第三方提供，可勾选不再显示。
class _DisclaimerBar extends StatelessWidget {
  const _DisclaimerBar({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '源由索引站抓取或自行导入，内容由第三方提供；请自行确认授权与合法性，使用后果自负。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
