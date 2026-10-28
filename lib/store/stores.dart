import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置项（shared_preferences 持久化）。
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

  // 主题：system / light / dark
  String get themeMode => _prefs.getString('theme.mode') ?? 'system';
  set themeMode(String v) {
    _prefs.setString('theme.mode', v);
    notifyListeners();
  }

  // 默认清晰度：best / worst / 720p / 1080p …
  String get defaultQuality => _prefs.getString('player.quality') ?? 'best';
  set defaultQuality(String v) {
    _prefs.setString('player.quality', v);
    notifyListeners();
  }

  // 默认倍速（字符串存，便于 UI 下拉）。
  String get defaultSpeed => _prefs.getString('player.speed') ?? '1.0';
  set defaultSpeed(String v) {
    _prefs.setString('player.speed', v);
    notifyListeners();
  }

  // 自动连播下一集。
  bool get autoNext => _prefs.getBool('player.autoNext') ?? true;
  set autoNext(bool v) {
    _prefs.setBool('player.autoNext', v);
    notifyListeners();
  }

  // 随机播放：从第 1 集开始（红果随机看的语义）。
  bool get randomFromFirst => _prefs.getBool('random.fromFirst') ?? true;
  set randomFromFirst(bool v) {
    _prefs.setBool('random.fromFirst', v);
    notifyListeners();
  }

  // 桌面端：打开视频时把窗口调成片源比例（竖屏剧竖着看）。
  bool get autoFitWindow => _prefs.getBool('player.autoFitWindow') ?? true;
  set autoFitWindow(bool v) {
    _prefs.setBool('player.autoFitWindow', v);
    notifyListeners();
  }

  // Windows 窗口记忆（仅桌面端使用）。
  String? get windowBounds => _prefs.getString('win.bounds');
  set windowBounds(String? v) {
    if (v == null) {
      _prefs.remove('win.bounds');
    } else {
      _prefs.setString('win.bounds', v);
    }
  }
}

/// 观看历史的一条记录（语义对齐 openhongguo internal/history.Entry）。
class HistoryEntry {
  HistoryEntry({
    required this.seriesId,
    this.title = '',
    this.coverUrl = '',
    this.episode = 1,
    this.episodes = 0,
    this.finished = false,
    this.position = 0,
    this.episodeId = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String seriesId;
  final String title;
  final String coverUrl;
  final int episode;
  final int episodes;
  final bool finished;
  final double position;
  final String episodeId;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'title': title,
        'cover_url': coverUrl,
        'episode': episode,
        'episodes': episodes,
        'finished': finished,
        'position': position,
        'episode_id': episodeId,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episode: json['episode'] as int? ?? 1,
        episodes: json['episodes'] as int? ?? 0,
        finished: json['finished'] as bool? ?? false,
        position: (json['position'] as num?)?.toDouble() ?? 0,
        episodeId: json['episode_id'] as String? ?? '',
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// 追剧状态。
enum FollowState { want, watching, watched }

/// 追剧的一条记录。
class FollowEntry {
  FollowEntry({
    required this.seriesId,
    this.title = '',
    this.coverUrl = '',
    this.episodeCount = 0,
    this.state = FollowState.watching,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String seriesId;
  final String title;
  final String coverUrl;
  final int episodeCount;
  final FollowState state;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'title': title,
        'cover_url': coverUrl,
        'episode_count': episodeCount,
        'state': state.name,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory FollowEntry.fromJson(Map<String, dynamic> json) => FollowEntry(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        state: FollowState.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => FollowState.watching,
        ),
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// 本地 JSON 文件存储的基类：原子写（tmp+rename），读失败当空。
abstract class _JsonFileStore extends ChangeNotifier {
  _JsonFileStore(this._fileName);

  final String _fileName;
  File? _file;
  bool _loaded = false;

  Future<File> get _fileFuture async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    return _file!;
  }

  Future<Map<String, dynamic>> _readJson() async {
    try {
      final f = await _fileFuture;
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeJson(Map<String, dynamic> json) async {
    final f = await _fileFuture;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await loadFromDisk();
  }

  @protected
  Future<void> loadFromDisk();

  @protected
  Future<void> persist(Map<String, dynamic> json);

  /// 备份导出用的原始数据。
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return _readJson();
  }

  /// 从备份 JSON 合并恢复：按 series_id，updatedAt 较新者胜。
  /// 返回合并进来的条数。
  Future<int> importData(Map<String, dynamic> incoming) async => 0;
}

/// 观看历史：series_id → 记录，最近更新在前。
class HistoryStore extends _JsonFileStore {
  HistoryStore() : super('aquan_history.json');

  final Map<String, HistoryEntry> _entries = {};

  List<HistoryEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  HistoryEntry? get(String seriesId) => _entries[seriesId];

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        _entries[k] = HistoryEntry.fromJson(v);
      }
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 播放器每 5 秒/暂停/退出时调用。
  Future<void> record({
    required String seriesId,
    required String title,
    required String coverUrl,
    required int episode,
    required int episodes,
    required String episodeId,
    required double position,
    required bool finished,
  }) async {
    await ensureLoaded();
    _entries[seriesId] = HistoryEntry(
      seriesId: seriesId,
      title: title,
      coverUrl: coverUrl,
      episode: episode,
      episodes: episodes,
      episodeId: episodeId,
      position: position,
      finished: finished,
    );
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }


  /// 用最新详情批量刷新封面（URL 变了才落盘一次）；返回更新的条数。
  Future<int> refreshCovers(Map<String, String> covers) async {
    await ensureLoaded();
    var changed = 0;
    covers.forEach((id, url) {
      if (url.isEmpty) return;
      final e = _entries[id];
      if (e != null && e.coverUrl != url) {
        _entries[id] = HistoryEntry(
          seriesId: e.seriesId,
          title: e.title,
          coverUrl: url,
          episode: e.episode,
          episodes: e.episodes,
          finished: e.finished,
          position: e.position,
          episodeId: e.episodeId,
          updatedAt: e.updatedAt,
        );
        changed++;
      }
    });
    if (changed > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
      notifyListeners();
    }
    return changed;
  }


  Future<void> clear() async {
    _entries.clear();
    await _writeJson({});
    notifyListeners();
  }

  Future<void> remove(String seriesId) async {
    _entries.remove(seriesId);
    await _writeJson({for (final e in _entries.entries) e.key: e.value.toJson()});
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {for (final e in _entries.entries) e.key: e.value.toJson()};
  }

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    var merged = 0;
    incoming.forEach((key, value) {
      if (value is! Map<String, dynamic>) return;
      final entry = HistoryEntry.fromJson(value);
      if (key.isEmpty || entry.seriesId.isEmpty) return;
      final existing = _entries[key];
      if (existing == null || entry.updatedAt.isAfter(existing.updatedAt)) {
        _entries[key] = entry;
        merged++;
      }
    });
    if (merged > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
      notifyListeners();
    }
    return merged;
  }
}

/// 追剧收藏：series_id → 记录。
class FollowStore extends _JsonFileStore {
  FollowStore() : super('aquan_follows.json');

  final Map<String, FollowEntry> _entries = {};

  List<FollowEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  bool isFollowing(String seriesId) => _entries.containsKey(seriesId);

  FollowEntry? get(String seriesId) => _entries[seriesId];

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        _entries[k] = FollowEntry.fromJson(v);
      }
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  Future<void> toggle({
    required String seriesId,
    required String title,
    required String coverUrl,
    required int episodeCount,
  }) async {
    await ensureLoaded();
    if (_entries.remove(seriesId) != null) {
      notifyListeners();
    } else {
      await follow(
        seriesId: seriesId,
        title: title,
        coverUrl: coverUrl,
        episodeCount: episodeCount,
      );
    }
    await _flush();
  }

  Future<void> follow({
    required String seriesId,
    required String title,
    required String coverUrl,
    required int episodeCount,
    FollowState state = FollowState.watching,
  }) async {
    _entries[seriesId] = FollowEntry(
      seriesId: seriesId,
      title: title,
      coverUrl: coverUrl,
      episodeCount: episodeCount,
      state: state,
    );
    await _flush();
  }

  Future<void> _flush() async {
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  /// 用最新详情批量刷新封面（URL 变了才落盘一次）；返回更新的条数。
  Future<int> refreshCovers(Map<String, String> covers) async {
    await ensureLoaded();
    var changed = 0;
    covers.forEach((id, url) {
      if (url.isEmpty) return;
      final e = _entries[id];
      if (e != null && e.coverUrl != url) {
        _entries[id] = FollowEntry(
          seriesId: e.seriesId,
          title: e.title,
          coverUrl: url,
          episodeCount: e.episodeCount,
          state: e.state,
          updatedAt: e.updatedAt,
        );
        changed++;
      }
    });
    if (changed > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
      notifyListeners();
    }
    return changed;
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {for (final e in _entries.entries) e.key: e.value.toJson()};
  }

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    var merged = 0;
    incoming.forEach((key, value) {
      if (value is! Map<String, dynamic>) return;
      final entry = FollowEntry.fromJson(value);
      if (key.isEmpty || entry.seriesId.isEmpty) return;
      final existing = _entries[key];
      if (existing == null || entry.updatedAt.isAfter(existing.updatedAt)) {
        _entries[key] = entry;
        merged++;
      }
    });
    if (merged > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
      notifyListeners();
    }
    return merged;
  }
}

/// 备份文件结构：{"aquan_backup": 1, "history": {…}, "follows": {…}}。
class Backup {
  Backup._();

  static const version = 1;

  static Map<String, dynamic> build(
    Map<String, dynamic> history,
    Map<String, dynamic> follows,
  ) =>
      {
        'aquan_backup': version,
        'history': history,
        'follows': follows,
      };

  /// 解析并校验；不是本应用的备份时抛 FormatException。
  static (Map<String, dynamic>, Map<String, dynamic>) parse(
      Map<String, dynamic> raw) {
    if (raw['aquan_backup'] != version) {
      throw const FormatException('不是阿圈短剧的备份文件');
    }
    final history = raw['history'];
    final follows = raw['follows'];
    return (
      history is Map<String, dynamic> ? history : <String, dynamic>{},
      follows is Map<String, dynamic> ? follows : <String, dynamic>{},
    );
  }
}

/// 搜索历史：最近提交过的关键词，新词置顶、去重、上限 20 条。
class SearchHistoryStore extends _JsonFileStore {
  SearchHistoryStore() : super('aquan_search_history.json');

  /// UI 显示与持久化的上限；超出时淘汰最旧的。
  static const maxEntries = 20;

  static const _key = 'queries';

  List<String> _queries = [];

  /// 最新在前；只读视图。
  List<String> get queries => List.unmodifiable(_queries);

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    final raw = json[_key];
    _queries = [
      if (raw is List<Object?>)
        for (final q in raw)
          if (q is String && q.trim().isNotEmpty) q,
    ];
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 记录一次搜索：已存在的词移到最前，其余顺移，超限淘汰最旧的。
  Future<void> record(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await ensureLoaded();
    _queries
      ..remove(q)
      ..insert(0, q);
    if (_queries.length > maxEntries) {
      _queries = _queries.sublist(0, maxEntries);
    }
    await _save();
  }

  Future<void> remove(String query) async {
    await ensureLoaded();
    if (_queries.remove(query)) await _save();
  }

  Future<void> clear() async {
    await ensureLoaded();
    if (_queries.isEmpty) return;
    _queries = [];
    await _save();
  }

  Future<void> _save() async {
    await _writeJson({_key: _queries});
    notifyListeners();
  }
}

/// 一条离线下载记录：加密 MP4 的落盘位置 + 播放所需的 CENC 密钥。
/// 密钥按集稳定（2026-10-29 实测：同一集重复解析结果一致），随文件缓存后
/// 本地播放不再需要网络；未加密剧集 keyHex 为空。
class DownloadEntry {
  const DownloadEntry({
    required this.seriesId,
    required this.seriesTitle,
    required this.coverUrl,
    required this.episodeId,
    required this.number,
    required this.title,
    required this.filePath,
    required this.sizeBytes,
    required this.keyHex,
    required this.quality,
    required this.downloadedAt,
  });

  final String seriesId;
  final String seriesTitle;
  final String coverUrl;
  final String episodeId;
  final int number;
  final String title;
  final String filePath;
  final int sizeBytes;
  final String keyHex;
  final String quality;
  final DateTime downloadedAt;

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'series_title': seriesTitle,
        'cover_url': coverUrl,
        'episode_id': episodeId,
        'number': number,
        'title': title,
        'file_path': filePath,
        'size_bytes': sizeBytes,
        'key_hex': keyHex,
        'quality': quality,
        'downloaded_at': downloadedAt.toIso8601String(),
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> json) => DownloadEntry(
        seriesId: json['series_id'] as String? ?? '',
        seriesTitle: json['series_title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeId: json['episode_id'] as String? ?? '',
        number: json['number'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        filePath: json['file_path'] as String? ?? '',
        sizeBytes: json['size_bytes'] as int? ?? 0,
        keyHex: json['key_hex'] as String? ?? '',
        quality: json['quality'] as String? ?? '',
        downloadedAt:
            DateTime.tryParse(json['downloaded_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// 一部已缓存剧的聚合视图（下载管理页用）。
class DownloadedSeries {
  const DownloadedSeries({
    required this.seriesId,
    required this.title,
    required this.coverUrl,
    required this.episodes,
    required this.totalBytes,
  });

  final String seriesId;
  final String title;
  final String coverUrl;
  final List<DownloadEntry> episodes;
  final int totalBytes;
}

/// 离线下载清单：seriesId → episodeId → 记录。
class DownloadStore extends _JsonFileStore {
  DownloadStore() : super('aquan_downloads.json');

  final Map<String, Map<String, DownloadEntry>> _series = {};

  /// 某一集的记录；未缓存返回 null。
  DownloadEntry? entryOf(String episodeId) {
    for (final eps in _series.values) {
      final e = eps[episodeId];
      if (e != null) return e;
    }
    return null;
  }

  bool has(String episodeId) => entryOf(episodeId) != null;

  /// 一部剧已缓存的集（按集数排序）。
  List<DownloadEntry> episodesOf(String seriesId) {
    final eps = _series[seriesId]?.values.toList() ?? const <DownloadEntry>[];
    eps.sort((a, b) => a.number.compareTo(b.number));
    return eps;
  }

  /// 全部已缓存剧（按最近下载时间排序，供管理页）。
  List<DownloadedSeries> get seriesList {
    final list = <DownloadedSeries>[];
    for (final entry in _series.values.expand((m) => m.values)) {
      final existing = list.where((s) => s.seriesId == entry.seriesId).toList();
      if (existing.isEmpty) {
        list.add(DownloadedSeries(
          seriesId: entry.seriesId,
          title: entry.seriesTitle,
          coverUrl: entry.coverUrl,
          episodes: episodesOf(entry.seriesId),
          totalBytes: episodesOf(entry.seriesId)
              .fold<int>(0, (sum, e) => sum + e.sizeBytes),
        ));
      }
    }
    list.sort((a, b) => b.episodes.last.downloadedAt
        .compareTo(a.episodes.last.downloadedAt));
    return list;
  }

  int get totalBytes => _series.values
      .expand((m) => m.values)
      .fold<int>(0, (sum, e) => sum + e.sizeBytes);

  /// 记录一条；同集重复下载以新记录为准。
  Future<void> record(DownloadEntry e) async {
    await ensureLoaded();
    (_series[e.seriesId] ??= {})[e.episodeId] = e;
    await _writeJson({
      for (final s in _series.entries)
        s.key: {for (final x in s.value.entries) x.key: x.value.toJson()},
    });
    notifyListeners();
  }

  Future<void> removeEpisode(String episodeId) async {
    await ensureLoaded();
    for (final eps in _series.values) {
      if (eps.remove(episodeId) != null) break;
    }
    _series.removeWhere((_, eps) => eps.isEmpty);
    await _save();
  }

  Future<void> removeSeries(String seriesId) async {
    await ensureLoaded();
    if (_series.remove(seriesId) == null) return;
    await _save();
  }

  Future<void> _save() async {
    await _writeJson({
      for (final s in _series.entries)
        s.key: {for (final x in s.value.entries) x.key: x.value.toJson()},
    });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _series.clear();
    json.forEach((seriesId, eps) {
      if (eps is! Map<String, dynamic>) return;
      final map = <String, DownloadEntry>{};
      eps.forEach((episodeId, v) {
        if (v is Map<String, dynamic>) {
          map[episodeId] = DownloadEntry.fromJson(v);
        }
      });
      if (map.isNotEmpty) _series[seriesId] = map;
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}
