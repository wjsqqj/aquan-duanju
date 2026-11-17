import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

/// 发现页首屏快照：冷启动先渲染它，后台再用最新一页覆盖。
///
/// 只缓存默认类型/频道（短剧·推荐）：把「上次在小说频道」的列表当首页缓存，
/// 下次启动会先闪一屏小说再跳回短剧，比白屏更难受。
class DiscoverSnapshot {
  const DiscoverSnapshot({
    required this.typeKey,
    required this.channelKey,
    required this.savedAtMs,
    required this.items,
    this.badges = const <String, String>{},
  });

  /// `ContentType.name`。
  final String typeKey;

  /// 频道稳定键（`channelKey(type, channel)` 的结果）。
  final String channelKey;
  final int savedAtMs;
  final List<SeriesSummary> items;

  /// 条目 id → 角标文案（名次/广告），与列表同生共死。
  final Map<String, String> badges;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': DiscoverCacheStore.formatVersion,
    'type': typeKey,
    'channel': channelKey,
    'savedAt': savedAtMs,
    'items': <Map<String, dynamic>>[for (final item in items) _itemToJson(item)],
    'badges': badges,
  };
}

Map<String, dynamic> _itemToJson(SeriesSummary item) => <String, dynamic>{
  'id': item.id,
  'title': item.title,
  'description': item.description,
  'cover_url': item.coverUrl,
  'cover_expires_at': item.coverExpiresAt,
  'episode_count': item.episodeCount,
  'author': item.author,
  'category': item.category,
  'words': item.words,
  'heat': item.heat,
  'play_count': item.playCount,
  'tags': item.tags,
};

/// 发现页首屏缓存的读写。
///
/// 与其余 store 同一套约定：原子写（`.tmp` → rename）、坏文件当没有、
/// 任何 IO 异常都吞掉（缓存只是优化，不能阻断首页）。
class DiscoverCacheStore {
  DiscoverCacheStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const int maxItems = 48;
  static const String fileName = 'aquan_discover_cache.json';
  static const int formatVersion = 1;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}${Platform.pathSeparator}$fileName');

  /// 读缓存；类型/频道不匹配、文件不存在、JSON 坏掉都返回 null。
  Future<DiscoverSnapshot?> load({
    required String typeKey,
    required String channelKey,
  }) async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      if (decoded['version'] != formatVersion) return null;
      if (decoded['type'] != typeKey || decoded['channel'] != channelKey) {
        return null;
      }
      final rawItems = decoded['items'];
      if (rawItems is! List) return null;
      final items = <SeriesSummary>[];
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final item = SeriesSummary.fromJson(Map<String, dynamic>.from(raw));
        if (item.id.isEmpty) continue;
        items.add(item);
      }
      if (items.isEmpty) return null;
      final rawBadges = decoded['badges'];
      final badges = <String, String>{};
      if (rawBadges is Map) {
        rawBadges.forEach((key, value) {
          if (key is String && value is String) badges[key] = value;
        });
      }
      return DiscoverSnapshot(
        typeKey: typeKey,
        channelKey: channelKey,
        savedAtMs: decoded['savedAt'] is num
            ? (decoded['savedAt'] as num).toInt()
            : 0,
        items: items,
        badges: badges,
      );
    } catch (_) {
      return null;
    }
  }

  /// 写缓存：只留前 [maxItems] 条，失败静默。
  Future<void> save(DiscoverSnapshot snapshot) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final kept = snapshot.items.take(maxItems).toList();
      final badges = <String, String>{};
      for (final item in kept) {
        final badge = snapshot.badges[item.id];
        if (badge != null) badges[item.id] = badge;
      }
      final limited = DiscoverSnapshot(
        typeKey: snapshot.typeKey,
        channelKey: snapshot.channelKey,
        savedAtMs: snapshot.savedAtMs,
        items: kept,
        badges: badges,
      );
      final temp = File('${file.path}.tmp-$pid');
      await temp.writeAsString(jsonEncode(limited.toJson()), flush: true);
      await temp.rename(file.path);
    } catch (_) {
      // 缓存写失败不影响首页。
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
