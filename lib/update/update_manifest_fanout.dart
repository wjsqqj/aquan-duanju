/// 多源清单的「版本优先」选择。
///
/// 更新检查的失效根因是**只看速度**：某个镜像测速最快，但它的
/// `releases/latest/download/update.json` 被 CDN 缓存住了，返回的是旧版本；
/// 旧逻辑「第一个能解析的清单就返回」于是直接得出「没有更新」。
///
/// 这里把「版本」与「速度」拆成两级排序：
/// 1. 先在所有候选清单里挑**版本号最大**的（同版本用 `versionCode` 兜底）；
/// 2. 版本相同时，才轮到调用方给的顺序（即测速结果）——先到先得。
///
/// 纯函数：不测速、不发请求，便于单测把「快但旧」这类现场直接复现。
library;

import 'update_manifest.dart';

/// 一个源 + 它返回的清单。
class ManifestCandidate<T> {
  const ManifestCandidate({required this.item, required this.manifest});

  /// 调用方的源对象（`UpdateDownloadSource` / 测试里的简单结构）。
  final T item;
  final UpdateManifest manifest;
}

/// 版本落后于胜者的候选（只用于日志，不参与选择）。
class ManifestBehind<T> {
  const ManifestBehind({required this.candidate, required this.note});

  final ManifestCandidate<T> candidate;

  /// 形如 `v1.12.9 < v1.12.10`；同版本号时带构建号 `v1.12.10(87) < v1.12.10(88)`。
  final String note;
}

class ManifestSelection<T> {
  const ManifestSelection({required this.winner, required this.behind});

  final ManifestCandidate<T> winner;

  /// 版本落后的候选；同版本的落选者不算落后（它们只是慢）。
  final List<ManifestBehind<T>> behind;

  String get version => winner.manifest.version;
}

/// 清单版本比较：语义版本优先，完全相等时才比较 `versionCode`。
///
/// `versionCode` 只做兜底（`--split-per-abi` 会带偏移，本仓已在
/// [UpdateManifest.versionCodeComparable] 里限定过可用范围；这里只比清单侧
/// 声明的 base 值，不掺设备值）。
int compareManifestVersions(UpdateManifest a, UpdateManifest b) {
  final core = UpdateManifest.compareVersions(a.version, b.version);
  if (core != 0) return core;
  return a.versionCode.compareTo(b.versionCode);
}

/// 选出版本最新的候选；同版本取 [candidates] 里靠前的（速度序）。
///
/// 返回 null 表示没有候选（全部源都抓不到清单）。
ManifestSelection<T>? selectFreshestManifest<T>(
  List<ManifestCandidate<T>> candidates,
) {
  if (candidates.isEmpty) return null;

  var bestIndex = 0;
  for (var i = 1; i < candidates.length; i++) {
    if (compareManifestVersions(
          candidates[i].manifest,
          candidates[bestIndex].manifest,
        ) >
        0) {
      bestIndex = i;
    }
  }
  final best = candidates[bestIndex];
  final behind = <ManifestBehind<T>>[];
  for (final candidate in candidates) {
    if (compareManifestVersions(candidate.manifest, best.manifest) < 0) {
      behind.add(
        ManifestBehind<T>(
          candidate: candidate,
          note: '${_describe(candidate.manifest)} < ${_describe(best.manifest)}',
        ),
      );
    }
  }
  return ManifestSelection<T>(
    winner: best,
    behind: List<ManifestBehind<T>>.unmodifiable(behind),
  );
}

String _describe(UpdateManifest manifest) => manifest.versionCode > 0
    ? 'v${manifest.version}(${manifest.versionCode})'
    : 'v${manifest.version}';
