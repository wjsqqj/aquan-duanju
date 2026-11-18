/// 短剧数据云同步文档 + 合并纯函数（无 IO、无 store 依赖，可完全单测）。
///
/// 远端文档 `aquan-watch-sync.json`（与书库 zip 完全独立，互不覆盖）：
/// ```json
/// { "version": 1, "exportedAt": 0, "history": [...], "follows": [...],
///   "tombstones": [{"kind": "history|follow", "id": "...", "deletedAt": 0}] }
/// ```
/// 条目是各 Store `toJson()` 的原样 JSON（`series_id` 在内），不转强类型——
/// 未知字段往返不丢，旧文档向后兼容。
///
/// 合并规则（吸收 open-apex-drama 04 报告实战参数）：
/// - 条目级新者胜：按 `series_id` 归并，`updated_at` 较新者赢；**同刻本地赢**
///   （时间戳无法区分先后时，保守保留本地现状，避免两台设备来回覆盖）。
/// - 墓碑传播：本地删除由服务层记墓碑（kind+id+deletedAt，180 天过期）；
///   远端墓碑命中（deletedAt 不早于条目时间）→ 删本地条目；条目比墓碑新 →
///   条目复活、墓碑作废清理（删了又看的场景）。
/// - 内容签名：忽略 `exportedAt` 的规范化 JSON SHA-256——合并结果与远端相同
///   → 跳过上传（省流量省请求）。
/// - 墓碑数量上限保护：超过 [WatchSyncDocument.tombstoneLimit] 全量清一次最老。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// 远端文档损坏（非 JSON / 结构错 / 版本过新）。
///
/// 参考仓教训：云端数据解析失败必须**中止同步**而不是当空表覆盖——
/// 否则一次坏响应就把用户云端数据抹掉。
class WatchSyncFormatException implements Exception {
  const WatchSyncFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 条目种类：观看历史 / 追剧。
enum WatchEntryKind { history, follow }

/// 删除墓碑：某设备删了这条记录，其他设备据此删本地（180 天过期）。
class WatchTombstone {
  const WatchTombstone({
    required this.kind,
    required this.id,
    required this.deletedAt,
  });

  final WatchEntryKind kind;
  final String id;

  /// 删除时刻（毫秒 epoch）。
  final int deletedAt;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    'deletedAt': deletedAt,
  };

  /// 字段级容错：坏数据返回 null（调用方跳过，不让一条坏墓碑炸掉整个文档）。
  static WatchTombstone? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = WatchEntryKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (kind == null) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final deletedAt = (raw['deletedAt'] as num?)?.toInt() ?? 0;
    return WatchTombstone(kind: kind, id: id, deletedAt: deletedAt);
  }
}

/// 云端同步文档（历史条目 / 追剧条目 / 墓碑）。
class WatchSyncDocument {
  const WatchSyncDocument({
    this.version = currentVersion,
    this.exportedAt = 0,
    this.history = const [],
    this.follows = const [],
    this.tombstones = const [],
  });

  static const int currentVersion = 1;

  /// 墓碑数量上限：超过则清一次最老的（防止长期使用后文档无限膨胀）。
  static const int tombstoneLimit = 2000;

  /// 墓碑保留时长：180 天后过期清理（与参考仓一致）。
  static const Duration tombstoneRetention = Duration(days: 180);

  /// 文档版本（> [currentVersion] = 更新的应用写的 → 中止同步防丢数据）。
  final int version;

  /// 上传时刻（毫秒 epoch，仅可读，不参与合并与签名）。
  final int exportedAt;

  /// 观看历史条目（HistoryEntry.toJson() 原样 map，`series_id` 在内）。
  final List<Map<String, dynamic>> history;

  /// 追剧条目（FollowEntry.toJson() 原样 map）。
  final List<Map<String, dynamic>> follows;

  final List<WatchTombstone> tombstones;

  factory WatchSyncDocument.empty() => const WatchSyncDocument();

  Map<String, dynamic> toJson() => {
    'version': currentVersion,
    'exportedAt': exportedAt,
    'history': history,
    'follows': follows,
    'tombstones': [for (final t in tombstones) t.toJson()],
  };

  /// 解析远端文档；格式损坏抛 [WatchSyncFormatException] 中止同步。
  factory WatchSyncDocument.parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const WatchSyncFormatException('远端同步文档不是有效 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const WatchSyncFormatException('远端同步文档结构无效');
    }
    final version = (decoded['version'] as num?)?.toInt() ?? currentVersion;
    if (version > currentVersion) {
      throw WatchSyncFormatException(
        '远端同步文档版本过新（$version > $currentVersion），请先升级应用',
      );
    }
    final tombstones = <WatchTombstone>[];
    final rawTombs = decoded['tombstones'];
    if (rawTombs is List) {
      for (final raw in rawTombs) {
        final tombstone = WatchTombstone.tryFromJson(raw);
        if (tombstone != null) tombstones.add(tombstone);
      }
    }
    return WatchSyncDocument(
      version: version,
      exportedAt: (decoded['exportedAt'] as num?)?.toInt() ?? 0,
      history: _entryList(decoded['history']),
      follows: _entryList(decoded['follows']),
      tombstones: tombstones,
    );
  }

  /// 条目列表：只收带 `series_id` 的对象（坏条目跳过，不让半坏文档炸同步）。
  static List<Map<String, dynamic>> _entryList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic> && _idOf(item).isNotEmpty) item,
    ];
  }

  /// 内容签名：规范化 JSON（键排序 + 条目按 id 排序）的 SHA-256。
  ///
  /// 刻意排除 `exportedAt` 与排版差异——内容相同就跳过上传 / 落盘。
  String contentSignature() {
    final canonical = <String, dynamic>{
      'version': currentVersion,
      'history': [for (final e in _sortedById(history)) e],
      'follows': [for (final e in _sortedById(follows)) e],
      'tombstones': [for (final t in _sortedTombstones) t.toJson()],
    };
    return sha256.convert(utf8.encode(_canonicalJson(canonical))).toString();
  }

  List<WatchTombstone> get _sortedTombstones {
    final list = List<WatchTombstone>.of(tombstones)
      ..sort((a, b) {
        final byKind = a.kind.name.compareTo(b.kind.name);
        return byKind != 0 ? byKind : a.id.compareTo(b.id);
      });
    return list;
  }

  static List<Map<String, dynamic>> _sortedById(
    List<Map<String, dynamic>> list,
  ) {
    final sorted = List<Map<String, dynamic>>.of(list)
      ..sort((a, b) => _idOf(a).compareTo(_idOf(b)));
    return sorted;
  }

  /// 递归键排序的 JSON（同内容不同键序 → 同签名）。
  static String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.toList()..sort((a, b) => '$a'.compareTo('$b'));
      return '{${[for (final k in keys) '${jsonEncode('$k')}:${_canonicalJson(value[k])}'].join(',')}}';
    }
    if (value is List) {
      return '[${[for (final item in value) _canonicalJson(item)].join(',')}]';
    }
    return jsonEncode(value);
  }
}

String _idOf(Map<String, dynamic> entry) =>
    entry['series_id']?.toString() ?? '';

/// 条目 `updated_at` → 毫秒 epoch。兼容 ISO8601 字符串（本仓 toJson 现状）与
/// 数字毫秒（防御未来格式）；**缺失/坏值返回 0**——旧 JSON 无时间戳视为最旧，
/// 任何真实时间都会赢，且同刻比较时天然让位本地。
int entryTimeMs(Map<String, dynamic> entry) {
  final raw = entry['updated_at'];
  if (raw is num) return raw.toInt();
  if (raw is String) {
    final ms = int.tryParse(raw);
    if (ms != null) return ms;
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
  }
  return 0;
}

/// 合并结果：合并后的完整文档（可上传）+ 需要应用到本地的增量。
class WatchMergeOutcome {
  const WatchMergeOutcome({
    required this.document,
    required this.historyToApply,
    required this.followsToApply,
    required this.historyTombstoneHits,
    required this.followsTombstoneHits,
  });

  /// 合并后的文档（条目 + 墓碑并集）。
  final WatchSyncDocument document;

  /// 本地缺失或远端较新的历史条目（服务层经 `importData` 新者胜写入）。
  final List<Map<String, dynamic>> historyToApply;

  /// 本地缺失或远端较新的追剧条目。
  final List<Map<String, dynamic>> followsToApply;

  /// 命中本地条目的远端墓碑（服务层删除前再做一次复活检查）。
  final List<WatchTombstone> historyTombstoneHits;

  /// 命中本地条目的追剧墓碑。
  final List<WatchTombstone> followsTombstoneHits;

  /// 本地是否有要写的变化（没有 → 不碰本地 store，不触发一轮通知）。
  bool get hasLocalChanges =>
      historyToApply.isNotEmpty ||
      followsToApply.isNotEmpty ||
      historyTombstoneHits.isNotEmpty ||
      followsTombstoneHits.isNotEmpty;
}

/// 双向合并：本地文档（本地条目 + 本地墓碑）+ 远端文档 → 合并结果。
///
/// 纯函数：不读文件、不碰 store、不联网。
WatchMergeOutcome mergeWatchDocuments({
  required WatchSyncDocument local,
  required WatchSyncDocument remote,
  required int nowMs,
}) {
  // ---- 墓碑：两侧并集（同 id 取较新），先清过期 ----
  final retentionMs = WatchSyncDocument.tombstoneRetention.inMilliseconds;
  final tombstones = <String, WatchTombstone>{};
  for (final t in [...local.tombstones, ...remote.tombstones]) {
    if (t.deletedAt > 0 && nowMs - t.deletedAt > retentionMs) continue; // 过期
    tombstones[t.key] = t;
  }

  // ---- 条目归并（history / follow 各跑一遍） ----
  final mergedHistory = <String, Map<String, dynamic>>{};
  final mergedFollows = <String, Map<String, dynamic>>{};
  final historyToApply = <Map<String, dynamic>>[];
  final followsToApply = <Map<String, dynamic>>[];
  final historyHits = <WatchTombstone>[];
  final followsHits = <WatchTombstone>[];

  void mergeKind(
    WatchEntryKind kind,
    List<Map<String, dynamic>> localEntries,
    List<Map<String, dynamic>> remoteEntries,
    Map<String, Map<String, dynamic>> mergedOut,
    List<Map<String, dynamic>> applyOut,
    List<WatchTombstone> hitOut,
  ) {
    final localById = {for (final e in localEntries) _idOf(e): e};
    final remoteById = {for (final e in remoteEntries) _idOf(e): e};

    for (final id in {...localById.keys, ...remoteById.keys}) {
      final localEntry = localById[id];
      final remoteEntry = remoteById[id];
      // 条目级新者胜；同刻本地赢（非严格大于即保本地）。
      Map<String, dynamic>? winner;
      if (localEntry != null && remoteEntry != null) {
        winner = entryTimeMs(remoteEntry) > entryTimeMs(localEntry)
            ? remoteEntry
            : localEntry;
      } else {
        winner = localEntry ?? remoteEntry;
      }

      final tombstone = tombstones['${kind.name}:$id'];
      if (tombstone != null) {
        if (winner != null && entryTimeMs(winner) > tombstone.deletedAt) {
          // 条目比墓碑新：删了又看 → 复活，墓碑作废。
          tombstones.remove('${kind.name}:$id');
        } else {
          // 墓碑命中（deletedAt 不早于条目时间，含条目缺失只剩墓碑的情况）
          // → 条目删除生效；墓碑保留到过期（其他设备可能还持有旧条目）。
          if (localEntry != null) {
            hitOut.add(tombstone);
          }
          continue;
        }
      }

      if (winner != null) {
        mergedOut[id] = winner;
        // 需要写本地：本地缺失，或合并结果严格比本地新。
        // 同刻（本地赢）时不重复写——内容就是本地自己的。
        if (localEntry == null ||
            entryTimeMs(winner) > entryTimeMs(localEntry)) {
          applyOut.add(winner);
        }
      }
    }
  }

  mergeKind(
    WatchEntryKind.history,
    local.history,
    remote.history,
    mergedHistory,
    historyToApply,
    historyHits,
  );
  mergeKind(
    WatchEntryKind.follow,
    local.follows,
    remote.follows,
    mergedFollows,
    followsToApply,
    followsHits,
  );

  // ---- 墓碑上限保护：超过上限清一次最老的 ----
  var kept = tombstones.values.toList();
  if (kept.length > WatchSyncDocument.tombstoneLimit) {
    kept.sort((a, b) => a.deletedAt.compareTo(b.deletedAt));
    kept = kept.sublist(kept.length - WatchSyncDocument.tombstoneLimit);
  }

  return WatchMergeOutcome(
    document: WatchSyncDocument(
      version: WatchSyncDocument.currentVersion,
      exportedAt: remote.exportedAt,
      history: mergedHistory.values.toList(),
      follows: mergedFollows.values.toList(),
      tombstones: kept,
    ),
    historyToApply: historyToApply,
    followsToApply: followsToApply,
    historyTombstoneHits: historyHits,
    followsTombstoneHits: followsHits,
  );
}

extension on WatchTombstone {
  String get key => '${kind.name}:$id';
}
