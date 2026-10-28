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
