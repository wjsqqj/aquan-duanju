import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/play_skip.dart';

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

  /// 播放音量（0-100），退出播放器时保存、启动时恢复。
  double get volume => _prefs.getDouble('player.volume') ?? 100.0;
  set volume(double v) {
    _prefs.setDouble('player.volume', v);
  }

  /// 离线缓存清晰度：默认 540p 省空间（全剧缓存体积约为 1080p 的一半）。
  String get cacheQuality => _prefs.getString('download.quality') ?? '540p';
  set cacheQuality(String v) {
    _prefs.setString('download.quality', v);
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

  // 桌面端：播放器处于迷你置顶小窗时，窗口尺寸变化不落盘（还原后再记）。
  bool get miniWindowActive => _prefs.getBool('win.mini') ?? false;
  set miniWindowActive(bool v) {
    _prefs.setBool('win.mini', v);
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

  // ---------- 播放器高级设置（带白名单 / 范围校验） ----------

  static const List<String> hwdecValues = [
    'auto-safe',
    'd3d11va',
    'd3d11va-copy',
    'dxva2',
    'nvdec',
    'cuda',
    'no',
  ];

  static const Map<String, String> hwdecLabels = {
    'auto-safe': '自动（推荐）',
    'd3d11va': 'D3D11VA 硬解',
    'd3d11va-copy': 'D3D11VA 拷回模式',
    'dxva2': 'DXVA2（旧显卡）',
    'nvdec': 'NVIDIA NVDEC',
    'cuda': 'NVIDIA CUDA',
    'no': '软件解码',
  };

  static const List<String> scaleValues = ['fit', 'fill', '16:9', '4:3'];
  static const Map<String, String> scaleLabels = {
    'fit': '适应窗口',
    'fill': '填充',
    '16:9': '强制 16:9',
    '4:3': '强制 4:3',
  };

  static const List<int> historyLimitOptions = [50, 100, 150, 200, 300, 500];

  static const int minHistoryLimit = 10;
  static const int maxHistoryLimit = 9999;
  static const int minCacheSecs = 5;
  static const int maxCacheSecs = 300;
  static const int minAudioDelayMs = -5000;
  static const int maxAudioDelayMs = 5000;

  static int normalizeHistoryLimit(int v) =>
      (v < minHistoryLimit || v > maxHistoryLimit) ? 150 : v;

  /// 硬解方式：Windows/macOS/Linux 可调；Android 固定 mediacodec（见播放器）。
  String get hwdecMode {
    final v = _prefs.getString('player.hwdec') ?? 'auto-safe';
    return hwdecValues.contains(v) ? v : 'auto-safe';
  }

  set hwdecMode(String v) {
    _prefs.setString(
        'player.hwdec', hwdecValues.contains(v) ? v : 'auto-safe');
    notifyListeners();
  }

  /// 网络缓冲时长（秒），写入 mpv 的 cache-secs。
  int get cacheSecs =>
      (_prefs.getInt('player.cacheSecs') ?? 30).clamp(minCacheSecs, maxCacheSecs);

  set cacheSecs(int v) {
    _prefs.setInt('player.cacheSecs', v.clamp(minCacheSecs, maxCacheSecs));
    notifyListeners();
  }

  /// 音画同步偏置（毫秒，正值表示音频延后）。
  int get audioDelayMs => (_prefs.getInt('player.audioDelayMs') ?? 0)
      .clamp(minAudioDelayMs, maxAudioDelayMs);

  set audioDelayMs(int v) {
    _prefs.setInt(
        'player.audioDelayMs', v.clamp(minAudioDelayMs, maxAudioDelayMs));
    notifyListeners();
  }

  String get scale {
    final v = _prefs.getString('player.scale') ?? 'fit';
    return scaleValues.contains(v) ? v : 'fit';
  }

  set scale(String v) {
    _prefs.setString('player.scale', scaleValues.contains(v) ? v : 'fit');
    notifyListeners();
  }

  /// 离线下载目录（空 = 应用数据目录下的 downloads）。
  /// 机器相关路径，不进入备份。
  String? get downloadDir {
    final v = _prefs.getString('download.dir')?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  set downloadDir(String? v) {
    final text = v?.trim() ?? '';
    if (text.isEmpty) {
      _prefs.remove('download.dir');
    } else {
      _prefs.setString('download.dir', text);
    }
    notifyListeners();
  }

  /// 下载限速（KB/s，0 = 不限速）。
  static const List<int> downloadSpeedOptions = [0, 256, 512, 1024, 2048, 5120];

  /// 同时下载数（1–3）。
  static const List<int> downloadConcurrencyOptions = [1, 2, 3];

  int get downloadConcurrency =>
      (_prefs.getInt('download.concurrency') ?? 1).clamp(1, 3);

  set downloadConcurrency(int v) {
    _prefs.setInt('download.concurrency', v.clamp(1, 3));
    notifyListeners();
  }

  /// 失败自动重试次数（0–3）。
  static const List<int> downloadRetryOptions = [0, 1, 2, 3];

  int get downloadRetries =>
      (_prefs.getInt('download.retries') ?? 0).clamp(0, 3);

  set downloadRetries(int v) {
    _prefs.setInt('download.retries', v.clamp(0, 3));
    notifyListeners();
  }

  int get downloadSpeedKbps =>
      (_prefs.getInt('download.speedKbps') ?? 0).clamp(0, 102400);

  set downloadSpeedKbps(int v) {
    _prefs.setInt('download.speedKbps', v.clamp(0, 102400));
    notifyListeners();
  }

  /// 字幕字号（mpv sub-font-size）。
  static const List<int> subtitleFontSizeOptions = [36, 42, 48, 56, 64];

  int get subtitleFontSize =>
      (_prefs.getInt('subtitle.fontSize') ?? 48).clamp(24, 96);

  set subtitleFontSize(int v) {
    _prefs.setInt('subtitle.fontSize', v.clamp(24, 96));
    notifyListeners();
  }

  bool get subtitleBorder => _prefs.getBool('subtitle.border') ?? true;
  set subtitleBorder(bool v) {
    _prefs.setBool('subtitle.border', v);
    notifyListeners();
  }

  bool get subtitleBackground =>
      _prefs.getBool('subtitle.background') ?? false;
  set subtitleBackground(bool v) {
    _prefs.setBool('subtitle.background', v);
    notifyListeners();
  }

  /// 片头片尾跳过总开关。
  bool get skipIntroOutro => _prefs.getBool('player.skipIntroOutro') ?? true;
  set skipIntroOutro(bool v) {
    _prefs.setBool('player.skipIntroOutro', v);
    notifyListeners();
  }

  /// 历史记录保留条数。
  int get historyLimit =>
      normalizeHistoryLimit(_prefs.getInt('history.limit') ?? 150);

  set historyLimit(int v) {
    _prefs.setInt('history.limit', normalizeHistoryLimit(v));
    notifyListeners();
  }

  /// 可携带到其它设备的设置（备份用）；窗口位置 / 迷你窗状态等本机状态除外。
  Map<String, dynamic> exportBackup() => {
        'theme.mode': themeMode,
        'player.quality': defaultQuality,
        'player.speed': defaultSpeed,
        'player.volume': volume,
        'player.autoNext': autoNext,
        'random.fromFirst': randomFromFirst,
        'player.autoFitWindow': autoFitWindow,
        'download.quality': cacheQuality,
        'download.speedKbps': downloadSpeedKbps,
        'download.concurrency': downloadConcurrency,
        'download.retries': downloadRetries,
        'history.limit': historyLimit,
        'player.hwdec': hwdecMode,
        'player.cacheSecs': cacheSecs,
        'player.audioDelayMs': audioDelayMs,
        'player.scale': scale,
        'player.skipIntroOutro': skipIntroOutro,
        'subtitle.fontSize': subtitleFontSize,
        'subtitle.border': subtitleBorder,
        'subtitle.background': subtitleBackground,
      };

  /// 从备份恢复设置：未知键忽略、非法值回落默认，返回实际写入的键数。
  int importBackup(Map<String, dynamic> data) {
    var applied = 0;
    void apply(String key, void Function() write) {
      if (!data.containsKey(key)) return;
      write();
      applied++;
    }

    apply('theme.mode', () {
      final v = data['theme.mode'];
      if (v is String && const ['system', 'light', 'dark'].contains(v)) {
        themeMode = v;
      }
    });
    apply('player.quality', () {
      final v = data['player.quality'];
      if (v is String && v.isNotEmpty) defaultQuality = v;
    });
    apply('player.speed', () {
      final v = data['player.speed'];
      if (v is String && double.tryParse(v) != null) defaultSpeed = v;
    });
    apply('player.volume', () {
      final v = data['player.volume'];
      if (v is num) volume = v.toDouble().clamp(0, 100);
    });
    apply('player.autoNext', () {
      final v = data['player.autoNext'];
      if (v is bool) autoNext = v;
    });
    apply('random.fromFirst', () {
      final v = data['random.fromFirst'];
      if (v is bool) randomFromFirst = v;
    });
    apply('player.autoFitWindow', () {
      final v = data['player.autoFitWindow'];
      if (v is bool) autoFitWindow = v;
    });
    apply('download.quality', () {
      final v = data['download.quality'];
      if (v is String && v.isNotEmpty) cacheQuality = v;
    });
    apply('download.speedKbps', () {
      final v = data['download.speedKbps'];
      if (v is num) downloadSpeedKbps = v.toInt();
    });
    apply('download.concurrency', () {
      final v = data['download.concurrency'];
      if (v is num) downloadConcurrency = v.toInt();
    });
    apply('download.retries', () {
      final v = data['download.retries'];
      if (v is num) downloadRetries = v.toInt();
    });
    apply('history.limit', () {
      final v = data['history.limit'];
      if (v is num) historyLimit = v.toInt();
    });
    apply('player.hwdec', () {
      final v = data['player.hwdec'];
      if (v is String && hwdecValues.contains(v)) hwdecMode = v;
    });
    apply('player.cacheSecs', () {
      final v = data['player.cacheSecs'];
      if (v is num) cacheSecs = v.toInt();
    });
    apply('player.audioDelayMs', () {
      final v = data['player.audioDelayMs'];
      if (v is num) audioDelayMs = v.toInt();
    });
    apply('player.scale', () {
      final v = data['player.scale'];
      if (v is String && scaleValues.contains(v)) scale = v;
    });
    apply('player.skipIntroOutro', () {
      final v = data['player.skipIntroOutro'];
      if (v is bool) skipIntroOutro = v;
    });
    apply('subtitle.fontSize', () {
      final v = data['subtitle.fontSize'];
      if (v is num) subtitleFontSize = v.toInt();
    });
    apply('subtitle.border', () {
      final v = data['subtitle.border'];
      if (v is bool) subtitleBorder = v;
    });
    apply('subtitle.background', () {
      final v = data['subtitle.background'];
      if (v is bool) subtitleBackground = v;
    });
    return applied;
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
    this.speed = 0,
    this.quality = '',
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

  /// 这部剧的播放偏好：speed 为 0 表示没改过倍速；quality 为空表示用全局默认。
  final double speed;
  final String quality;
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
        if (speed > 0) 'speed': speed,
        if (quality.isNotEmpty) 'quality': quality,
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
        speed: (json['speed'] as num?)?.toDouble() ?? 0,
        quality: json['quality'] as String? ?? '',
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
    int? latestEpisodeCount,
    this.state = FollowState.watching,
    DateTime? updatedAt,
  })  : latestEpisodeCount = latestEpisodeCount ?? episodeCount,
        updatedAt = updatedAt ?? DateTime.now();

  final String seriesId;
  final String title;
  final String coverUrl;
  final int episodeCount;

  /// 最近一次从服务端看到的集数；大于 [episodeCount] 即有更新。
  final int latestEpisodeCount;
  final FollowState state;
  DateTime updatedAt;

  /// 追剧的剧有新集（服务端集数多于追剧时的记录）。
  bool get hasUpdate => latestEpisodeCount > episodeCount;

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'title': title,
        'cover_url': coverUrl,
        'episode_count': episodeCount,
        'latest_episode_count': latestEpisodeCount,
        'state': state.name,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory FollowEntry.fromJson(Map<String, dynamic> json) => FollowEntry(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        latestEpisodeCount: json['latest_episode_count'] as int?,
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

  /// 写盘串行队列：播放进度、退出保存、备份恢复可能并发触发写盘，
  /// 共用同一个 `.tmp` 路径时并发写会互相覆盖；在这里统一排队。
  Future<void> _writeQueue = Future<void>.value();

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

  Future<void> _writeJson(Map<String, dynamic> json) {
    final encoded = jsonEncode(json);
    final task = _writeQueue.then((_) async {
      final f = await _fileFuture;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(f.path);
    });
    _writeQueue = task.catchError((_) {});
    return task;
  }

  Future<void>? _loadingFuture;

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    // 单飞：并发 record/import 时只加载一次，避免两个 loadFromDisk
    // 互相 clear，把刚写入的条目覆盖掉。
    return _loadingFuture ??= loadFromDisk().whenComplete(() {
      _loadingFuture = null;
    });
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

  static const int defaultLimit = 150;
  static const int minLimit = 1;
  static const int maxLimit = 9999;

  final Map<String, HistoryEntry> _entries = {};
  int _limit = defaultLimit;

  /// 保留条数（超出后淘汰最旧记录）。
  int get limit => _limit;

  set limit(int v) {
    _limit = (v < minLimit || v > maxLimit) ? defaultLimit : v;
  }

  List<HistoryEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  HistoryEntry? get(String seriesId) => _entries[seriesId];

  /// 调整上限并立即裁剪 / 落盘。
  Future<void> applyLimit(int v) async {
    limit = v;
    await ensureLoaded();
    if (_prune() > 0) await _flush();
  }

  /// 超出上限时淘汰最旧记录，返回删除条数。
  int _prune() {
    if (_entries.length <= _limit) return 0;
    final ordered = _entries.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    final keep = ordered.take(_limit).map((e) => e.key).toSet();
    final before = _entries.length;
    _entries.removeWhere((k, _) => !keep.contains(k));
    return before - _entries.length;
  }

  Future<void> _flush() async {
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        _entries[k] = HistoryEntry.fromJson(v);
      }
    });
    final pruned = _prune();
    _loaded = true;
    if (pruned > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
    }
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
    double speed = 0,
    String quality = '',
  }) async {
    await ensureLoaded();
    final existing = _entries[seriesId];
    _entries[seriesId] = HistoryEntry(
      seriesId: seriesId,
      title: title,
      coverUrl: coverUrl,
      episode: episode,
      episodes: episodes,
      episodeId: episodeId,
      position: position,
      finished: finished,
      // 进度回写不携带偏好时，保留用户此前手动选择的倍速/清晰度；
      // 否则自动换线选到的低清晰度会把「最高」偏好覆盖掉。
      speed: speed > 0 ? speed : (existing?.speed ?? 0),
      quality: quality.isNotEmpty ? quality : (existing?.quality ?? ''),
    );
    _prune();
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  /// 只写这部剧的播放偏好（倍速/清晰度），保留记录其余字段；
  /// 没有历史记录时建一条占位（不上进度）。
  Future<void> setPlaybackPrefs({
    required String seriesId,
    double? speed,
    String? quality,
  }) async {
    await ensureLoaded();
    final e = _entries[seriesId];
    _entries[seriesId] = HistoryEntry(
      seriesId: seriesId,
      title: e?.title ?? '',
      coverUrl: e?.coverUrl ?? '',
      episode: e?.episode ?? 1,
      episodes: e?.episodes ?? 0,
      episodeId: e?.episodeId ?? '',
      position: e?.position ?? 0,
      finished: e?.finished ?? false,
      speed: speed ?? e?.speed ?? 0,
      quality: quality ?? e?.quality ?? '',
      updatedAt: e?.updatedAt,
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
          speed: e.speed,
          quality: e.quality,
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
      _prune();
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

  /// 设置追剧状态（想看/在看/已看）；没追过的剧先按追剧处理。
  /// 返回 true 表示该剧在追（无论状态是什么）。
  Future<bool> setStateOf({
    required String seriesId,
    required FollowState state,
    String title = '',
    String coverUrl = '',
    int episodeCount = 0,
  }) async {
    await ensureLoaded();
    final existing = _entries[seriesId];
    if (existing == null) {
      if (title.isEmpty) return false;
      await follow(
        seriesId: seriesId,
        title: title,
        coverUrl: coverUrl,
        episodeCount: episodeCount,
        state: state,
      );
      return true;
    }
    if (existing.state != state) {
      _entries[seriesId] = FollowEntry(
        seriesId: existing.seriesId,
        title: existing.title,
        coverUrl: existing.coverUrl,
        episodeCount: existing.episodeCount,
        state: state,
        updatedAt: existing.updatedAt,
      );
      await _flush();
    }
    return true;
  }

  Future<void> _flush() async {
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  /// 用批量详情刷新封面与服务端集数（有变化才落盘一次）；返回更新的条数。
  Future<int> refreshFromDetails(List<Series> details) async {
    await ensureLoaded();
    var changed = 0;
    for (final d in details) {
      final e = _entries[d.id];
      if (e == null) continue;
      final cover = d.coverUrl;
      final latest = d.episodeCount;
      final coverChanged = cover.isNotEmpty && cover != e.coverUrl;
      final countChanged =
          latest > 0 && latest != e.latestEpisodeCount;
      if (!coverChanged && !countChanged) continue;
      _entries[d.id] = FollowEntry(
        seriesId: e.seriesId,
        title: e.title,
        coverUrl: coverChanged ? cover : e.coverUrl,
        episodeCount: e.episodeCount,
        latestEpisodeCount:
            countChanged ? latest : e.latestEpisodeCount,
        state: e.state,
        updatedAt: e.updatedAt,
      );
      changed++;
    }
    if (changed > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
      notifyListeners();
    }
    return changed;
  }

  /// 用户已看过更新（打开详情/继续观看）后，把记录追平并清除更新标记。
  Future<void> ackUpdate(String seriesId, int latestCount) async {
    await ensureLoaded();
    final e = _entries[seriesId];
    if (e == null || !e.hasUpdate) return;
    final seen = latestCount > 0 ? latestCount : e.latestEpisodeCount;
    _entries[seriesId] = FollowEntry(
      seriesId: e.seriesId,
      title: e.title,
      coverUrl: e.coverUrl,
      episodeCount: seen,
      state: e.state,
      updatedAt: e.updatedAt,
    );
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

/// 片头片尾跳过：series_id → 时间点，跨集继承、按剧记忆。
///
/// 文件格式：`{"version": 1, "items": {series_id: {opening_ms, ending_ms, updated_at}}}`。
/// 版本不符时保留原文件但按空处理（读取侧不因为半坏文件拖垮播放）。
class PlaySkipStore extends _JsonFileStore {
  PlaySkipStore() : super('aquan_play_skip.json');

  static const int formatVersion = 1;
  static const int maxEntries = 500;
  static const String _itemsKey = 'items';

  final Map<String, PlaySkipEntry> _entries = {};

  PlaySkipEntry? entryFor(String seriesId) => _entries[seriesId];

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    final rawItems = json[_itemsKey];
    if (json['version'] == formatVersion && rawItems is Map) {
      rawItems.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final entry = PlaySkipEntry.tryFromJson(value);
        if (entry != null && !entry.isEmpty) _entries[key] = entry;
      });
      _prune();
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 写入 / 覆盖某剧的时间点；空值等同于移除。
  Future<void> upsert(String seriesId, PlaySkipEntry entry) async {
    await ensureLoaded();
    if (entry.isEmpty) {
      _entries.remove(seriesId);
    } else {
      _entries[seriesId] = entry.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _prune();
    await _save();
  }

  Future<void> remove(String seriesId) =>
      upsert(seriesId, const PlaySkipEntry());

  Future<void> clear() async {
    await ensureLoaded();
    if (_entries.isEmpty) return;
    _entries.clear();
    await _save();
  }

  int _prune() {
    if (_entries.length <= maxEntries) return 0;
    final ordered = _entries.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    final keep = ordered.take(maxEntries).map((e) => e.key).toSet();
    final before = _entries.length;
    _entries.removeWhere((k, _) => !keep.contains(k));
    return before - _entries.length;
  }

  Future<void> _save() async {
    await _writeJson({
      'version': formatVersion,
      _itemsKey: {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      },
    });
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {
      _itemsKey: {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      },
    };
  }

  /// 合并恢复：同一条目取 updatedAt 较新者；返回合并进来的条数。
  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final rawItems = incoming[_itemsKey];
    if (rawItems is! Map) return 0;
    var merged = 0;
    rawItems.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final entry = PlaySkipEntry.tryFromJson(value);
      if (entry == null || entry.isEmpty) return;
      final existing = _entries[key];
      if (existing == null || entry.updatedAt >= existing.updatedAt) {
        _entries[key] = entry;
        merged++;
      }
    });
    if (merged > 0) {
      _prune();
      await _save();
    }
    return merged;
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
    if (_queries.length > maxEntries) {
      _queries = _queries.sublist(0, maxEntries);
    }
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

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {
      _key: List<String>.from(_queries),
    };
  }

  /// 合并恢复：保留现有顺序，把备份里的新词追加到末尾并去重。
  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final raw = incoming[_key];
    if (raw is! List) return 0;
    var added = 0;
    for (final q in raw) {
      if (q is! String) continue;
      final text = q.trim();
      if (text.isEmpty || _queries.contains(text)) continue;
      _queries.add(text);
      added++;
    }
    if (added > 0) {
      if (_queries.length > maxEntries) {
        _queries = _queries.sublist(0, maxEntries);
      }
      await _save();
    }
    return added;
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

  DownloadEntry copyWith({String? filePath}) => DownloadEntry(
        seriesId: seriesId,
        seriesTitle: seriesTitle,
        coverUrl: coverUrl,
        episodeId: episodeId,
        number: number,
        title: title,
        filePath: filePath ?? this.filePath,
        sizeBytes: sizeBytes,
        keyHex: keyHex,
        quality: quality,
        downloadedAt: downloadedAt,
      );

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

  /// 更新某集的落盘路径（下载目录迁移用）。
  Future<void> updateFilePath(String episodeId, String newPath) async {
    await ensureLoaded();
    for (final eps in _series.values) {
      final entry = eps[episodeId];
      if (entry == null) continue;
      eps[episodeId] = entry.copyWith(filePath: newPath);
      await _save();
      return;
    }
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

/// 阅读进度：一本书一条，与短剧观看历史分开存。
class ReadingEntry {
  ReadingEntry({
    required this.bookId,
    this.title = '',
    this.coverUrl = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.chapterIndex = 0,
    this.chapters = 0,
    this.offset = 0,
    this.manga = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String bookId;
  final String title;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final int chapterIndex;
  final int chapters;

  /// 漫画与小说共用这份记录：决定点开时进阅读器还是图片阅读器。
  final bool manga;

  /// 章节内的滚动位置（0..1），续读时用来还原。
  final double offset;
  final DateTime updatedAt;

  /// 整本进度（按章数粗算），用于「继续阅读」的进度条。
  double get percent =>
      chapters <= 0 ? 0 : ((chapterIndex + 1) / chapters).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'title': title,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_index': chapterIndex,
        'chapters': chapters,
        'offset': offset,
        'manga': manga,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ReadingEntry.fromJson(String bookId, Map<String, dynamic> json) =>
      ReadingEntry(
        bookId: bookId,
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        chapterId: json['chapter_id'] as String? ?? '',
        chapterTitle: json['chapter_title'] as String? ?? '',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        chapters: (json['chapters'] as num?)?.toInt() ?? 0,
        offset: (json['offset'] as num?)?.toDouble() ?? 0,
        manga: json['manga'] as bool? ?? false,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 小说阅读进度存储（`aquan_reading.json`）。
class ReadingProgressStore extends _JsonFileStore {
  ReadingProgressStore() : super('aquan_reading.json');

  final Map<String, ReadingEntry> _entries = {};

  /// 最近在读在前。
  List<ReadingEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  ReadingEntry? entry(String bookId) => _entries[bookId];

  Future<void> record({
    required String bookId,
    required String title,
    required String coverUrl,
    required String chapterId,
    required String chapterTitle,
    required int chapterIndex,
    required int chapters,
    required double offset,
    bool manga = false,
  }) async {
    await ensureLoaded();
    _entries[bookId] = ReadingEntry(
      bookId: bookId,
      title: title,
      coverUrl: coverUrl,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      chapters: chapters,
      offset: offset.clamp(0.0, 1.0),
      manga: manga,
    );
    await _flush();
  }

  Future<void> remove(String bookId) async {
    await ensureLoaded();
    if (_entries.remove(bookId) == null) return;
    await _flush();
  }

  Future<void> _flush() async {
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) _entries[k] = ReadingEntry.fromJson(k, v);
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

class _CachedChapter {
  _CachedChapter(this.text, this.savedAt);

  final String text;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
        'text': text,
        'saved_at': savedAt.toIso8601String(),
      };

  factory _CachedChapter.fromJson(Map<String, dynamic> json) =>
      _CachedChapter(
        json['text'] as String? ?? '',
        DateTime.tryParse(json['saved_at'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 章节正文缓存（`aquan_book_cache.json`）：断网也能读已看过的章节，
/// 超出上限按保存时间淘汰最旧的。
class BookChapterCache extends _JsonFileStore {
  BookChapterCache() : super('aquan_book_cache.json');

  static const int defaultLimit = 200;

  final Map<String, _CachedChapter> _items = {};
  int _limit = defaultLimit;

  int get limit => _limit;

  set limit(int v) => _limit = v < 1 ? defaultLimit : v;

  String? text(String itemId) => _items[itemId]?.text;

  Future<void> put(String itemId, String text) async {
    await ensureLoaded();
    _items[itemId] = _CachedChapter(text, DateTime.now());
    await _flush();
  }

  Future<void> remove(String itemId) async {
    await ensureLoaded();
    if (_items.remove(itemId) == null) return;
    await _flush();
  }

  Future<void> clear() async {
    await ensureLoaded();
    if (_items.isEmpty) return;
    _items.clear();
    await _flush();
  }

  Future<void> _flush() async {
    _prune();
    await _writeJson({
      for (final e in _items.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  void _prune() {
    if (_items.length <= _limit) return;
    final ordered = _items.entries.toList()
      ..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
    final keep = ordered.take(_limit).map((e) => e.key).toSet();
    _items.removeWhere((k, _) => !keep.contains(k));
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _items.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) _items[k] = _CachedChapter.fromJson(v);
    });
    _loaded = true;
    _prune();
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

/// 听书进度：与阅读进度**分开存**（`aquan_listen.json`），避免互相覆盖。
class ListenEntry {
  ListenEntry({
    required this.bookId,
    this.title = '',
    this.coverUrl = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.chapterIndex = 0,
    this.chapters = 0,
    this.toneId = 0,
    this.positionMs = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String bookId;
  final String title;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final int chapterIndex;
  final int chapters;

  /// 用的音色 id（换音色会重新从头播，这里只记最后使用的）。
  final int toneId;

  /// 章内播放位置（毫秒）。
  final int positionMs;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'title': title,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_index': chapterIndex,
        'chapters': chapters,
        'tone_id': toneId,
        'position_ms': positionMs,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ListenEntry.fromJson(String bookId, Map<String, dynamic> json) =>
      ListenEntry(
        bookId: bookId,
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        chapterId: json['chapter_id'] as String? ?? '',
        chapterTitle: json['chapter_title'] as String? ?? '',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        chapters: (json['chapters'] as num?)?.toInt() ?? 0,
        toneId: (json['tone_id'] as num?)?.toInt() ?? 0,
        positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 听书进度存储（`aquan_listen.json`）。
class ListenProgressStore extends _JsonFileStore {
  ListenProgressStore() : super('aquan_listen.json');

  final Map<String, ListenEntry> _entries = {};

  /// 最近在听的在前。
  List<ListenEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  ListenEntry? entry(String bookId) => _entries[bookId];

  Future<void> record({
    required String bookId,
    required String title,
    required String coverUrl,
    required String chapterId,
    required String chapterTitle,
    required int chapterIndex,
    required int chapters,
    required int toneId,
    required int positionMs,
  }) async {
    await ensureLoaded();
    _entries[bookId] = ListenEntry(
      bookId: bookId,
      title: title,
      coverUrl: coverUrl,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      chapters: chapters,
      toneId: toneId,
      positionMs: positionMs < 0 ? 0 : positionMs,
    );
    await _flush();
  }

  Future<void> remove(String bookId) async {
    await ensureLoaded();
    if (_entries.remove(bookId) == null) return;
    await _flush();
  }

  Future<void> _flush() async {
    await _writeJson({
      for (final e in _entries.entries) e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) _entries[k] = ListenEntry.fromJson(k, v);
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}