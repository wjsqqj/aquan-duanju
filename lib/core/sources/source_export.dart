import 'dart:convert';

import 'source_adapter.dart';
import 'source_market.dart';

/// 导出格式。
enum SourceExportFormat {
  sites('TVBox 单仓 sites'),
  multiRepo('影仓多仓 urls'),
  plainList('纯 URL 列表');

  const SourceExportFormat(this.label);

  final String label;
}

/// 已知的 GitHub 加速前缀：导出时还原成直链，避免把代理地址写进用户配置。
const List<String> _proxyPrefixes = <String>[
  'https://gh-proxy.org/',
  'https://ghproxy.com/',
  'https://mirror.ghproxy.com/',
  'https://ghproxy.net/',
  'https://raw.gitmirror.com/',
  'https://cdn.jsdelivr.net/gh/',
];

/// 清洗 URL：去掉已知代理前缀。
String cleanSourceUrl(String url) {
  var out = url.trim();
  for (final prefix in _proxyPrefixes) {
    if (out.toLowerCase().startsWith(prefix)) {
      out = out.substring(prefix.length);
      if (!out.startsWith('http://') && !out.startsWith('https://')) {
        out = 'https://$out';
      }
      break;
    }
  }
  return out;
}

int _tvboxType(SourceKind kind) => switch (kind) {
      SourceKind.cmsXml => 0,
      SourceKind.cmsJson => 1,
      SourceKind.spiderJs => 3,
      SourceKind.spider => 3,
    };

/// TVBox 单仓 `sites` JSON。
String exportSitesJson(List<SourceConfig> sources) {
  final sites = <Map<String, dynamic>>[];
  for (final source in sources) {
    final api = source.api.trim();
    if (api.isEmpty) continue;
    final entry = <String, dynamic>{
      'key': (source.spiderKey ?? source.id).trim(),
      'name': source.name.trim(),
      'type': _tvboxType(source.kind),
      'api': api,
      'searchable': 1,
      'quickSearch': 1,
      'filterable': 1,
    };
    if (source.headers.isNotEmpty) {
      entry['ext'] = jsonEncode(<String, dynamic>{'header': source.headers});
    }
    sites.add(entry);
  }
  return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
    'sites': sites,
  });
}

/// 影仓多仓 `{"urls":[{name,url}]}`：只取可用单仓叶子，按延迟升序、去重。
String exportMultiRepoJson(List<MarketNode> roots) {
  final entries = _exportableLeaves(roots);
  return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
    'urls': <Map<String, String>>[
      for (final leaf in entries)
        <String, String>{
          'name': leaf.$1,
          'url': leaf.$2,
        },
    ],
  });
}

/// 纯 URL 行文本。
String exportPlainUrls(List<MarketNode> roots) {
  final entries = _exportableLeaves(roots);
  return entries.map((e) => e.$2).join('\n');
}

/// 按格式导出。
String exportByFormat(
  SourceExportFormat format,
  List<MarketNode> roots, {
  List<SourceConfig> sources = const <SourceConfig>[],
}) =>
    switch (format) {
      SourceExportFormat.sites => exportSitesJson(sources),
      SourceExportFormat.multiRepo => exportMultiRepoJson(roots),
      SourceExportFormat.plainList => exportPlainUrls(roots),
    };

/// 可用单仓叶子 → (name, url)，延迟升序、URL 去重。
List<(String, String)> _exportableLeaves(List<MarketNode> roots) {
  final leaves = <MarketNode>[];
  for (final root in roots) {
    leaves.addAll(root.leaves());
  }
  leaves.sort((a, b) {
    final aa = a.totalMs ?? 1 << 30;
    final bb = b.totalMs ?? 1 << 30;
    return aa.compareTo(bb);
  });
  final seen = <String>{};
  final out = <(String, String)>[];
  for (final leaf in leaves) {
    final url = cleanSourceUrl(leaf.url);
    if (url.isEmpty || !seen.add(url)) continue;
    final name = leaf.name.trim().isEmpty ? url : leaf.name.trim();
    out.add((name, url));
  }
  return out;
}
