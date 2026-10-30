import '../../store/stores.dart';
import 'source_adapter.dart';
import 'source_market.dart';

/// 导入结果。
class ImportOutcome {
  const ImportOutcome({required this.imported, required this.skipped});

  const ImportOutcome.empty()
      : imported = 0,
        skipped = 0;

  final int imported;
  final int skipped;

  String get message => imported > 0
      ? '导入 $imported 条${skipped > 0 ? '，跳过 $skipped 条重复' : ''}'
      : (skipped > 0 ? '所选源都已存在' : '没有可导入的源');
}

/// 把扫描结果写进源注册表。
class MarketImporter {
  const MarketImporter._();

  /// 导入指定节点下的全部可用单仓候选。
  static Future<ImportOutcome> importNodes(
    SourcesStore store,
    Iterable<MarketNode> nodes,
  ) async {
    final candidates = <SourceCandidate>[];
    final seen = <String>{};
    for (final node in nodes) {
      if (!node.available || node.isMulti) continue;
      for (final candidate in node.candidates) {
        if (!candidate.usable) continue;
        final key = '${candidate.kind.name}|${_normalizeApi(candidate.api)}';
        if (!seen.add(key)) continue;
        candidates.add(candidate);
      }
    }
    if (candidates.isEmpty) return const ImportOutcome.empty();
    final added = await store.addCandidates(candidates);
    return ImportOutcome(
      imported: added,
      skipped: candidates.length - added,
    );
  }

  /// 导入全部可用单仓叶子。
  static Future<ImportOutcome> importAll(
    SourcesStore store,
    List<MarketNode> roots,
  ) {
    final leaves = <MarketNode>[];
    for (final root in roots) {
      leaves.addAll(root.leaves());
    }
    return importNodes(store, leaves);
  }

  /// 按总耗时升序取前 [count] 个可用单仓叶子导入。
  static Future<ImportOutcome> importTopN(
    SourcesStore store,
    List<MarketNode> roots,
    int count,
  ) {
    final leaves = <MarketNode>[];
    for (final root in roots) {
      leaves.addAll(root.leaves());
    }
    leaves.sort((a, b) {
      final aa = a.totalMs ?? 1 << 30;
      final bb = b.totalMs ?? 1 << 30;
      return aa.compareTo(bb);
    });
    return importNodes(store, leaves.take(count.clamp(1, 200)));
  }

  static String _normalizeApi(String api) {
    var out = api.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out.toLowerCase();
  }
}
