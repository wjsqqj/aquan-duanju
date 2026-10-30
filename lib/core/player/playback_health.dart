/// 播放线路健康度：按「源 / 影片 / 集 / 线路」四元组记成败，用于换线排序。
///
/// 与 `source_health.dart` 的区别：那个按**源**记（搜索/打开是否成功），
/// 这个按**一次具体播放**记——同一部剧的第 3 集在 A 线路卡、第 4 集在 A 线路正常，
/// 只有按集记才能区分。参考 tvbox `PlaybackHealthRepository` 的字段设计。
library;

/// 一次播放结果。
enum PlaybackHealthEvent {
  /// 正常播完或播了很久。
  success,

  /// 缓冲判定器报了卡顿（仍能播，只是体验差）。
  slowBuffer,

  /// 起播失败 / 解码错误 / 地址 404。
  failed,
}

/// 单条健康记录。
class PlaybackHealthRecord {
  PlaybackHealthRecord({
    required this.key,
    this.score = defaultScore,
    this.successes = 0,
    this.failures = 0,
    this.slowBuffers = 0,
    DateTime? updatedAt,
    this.cooldownUntil,
  }) : updatedAt = updatedAt ?? DateTime.now();

  static const int defaultScore = 60;
  static const int maxScore = 100;
  static const int minScore = 0;

  final String key;
  int score;
  int successes;
  int failures;
  int slowBuffers;
  DateTime updatedAt;
  DateTime? cooldownUntil;

  bool coolingDownAt(DateTime now) =>
      cooldownUntil != null && cooldownUntil!.isAfter(now);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'score': score,
        'ok': successes,
        'fail': failures,
        'slow': slowBuffers,
        'updated_at': updatedAt.toIso8601String(),
        if (cooldownUntil != null)
          'cooldown_until': cooldownUntil!.toIso8601String(),
      };

  factory PlaybackHealthRecord.fromJson(String key, Map<String, dynamic> json) =>
      PlaybackHealthRecord(
        key: key,
        score: (json['score'] as num?)?.toInt() ?? defaultScore,
        successes: (json['ok'] as num?)?.toInt() ?? 0,
        failures: (json['fail'] as num?)?.toInt() ?? 0,
        slowBuffers: (json['slow'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now(),
        cooldownUntil:
            DateTime.tryParse(json['cooldown_until'] as String? ?? ''),
      );
}

/// 健康度登记表（纯逻辑，落盘交给 store）。
class PlaybackHealthRegistry {
  PlaybackHealthRegistry({
    DateTime Function()? clock,
    this.maxEntries = 300,
    this.retention = const Duration(days: 30),
    this.failureCooldown = const Duration(minutes: 30),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final int maxEntries;
  final Duration retention;

  /// 起播失败后的冷却：这段时间内该线路排到最后，但仍保留（可能只是临时抽风）。
  final Duration failureCooldown;

  final Map<String, PlaybackHealthRecord> _records =
      <String, PlaybackHealthRecord>{};

  Map<String, PlaybackHealthRecord> get records =>
      Map<String, PlaybackHealthRecord>.unmodifiable(_records);

  /// 拼 key：`源|影片|集|线路`。空字段用 `-` 占位，避免 `||` 混淆。
  static String keyOf({
    required String sourceKey,
    required String seriesId,
    int episode = 0,
    int line = 0,
  }) =>
      '${_part(sourceKey)}|${_part(seriesId)}|$episode|$line';

  static String _part(String value) => value.isEmpty ? '-' : value;

  void record(
    String key,
    PlaybackHealthEvent event, {
    DateTime? at,
  }) {
    if (key.isEmpty) return;
    final now = at ?? _clock();
    final record = _records.putIfAbsent(
      key,
      () => PlaybackHealthRecord(key: key, updatedAt: now),
    );
    record.updatedAt = now;
    switch (event) {
      case PlaybackHealthEvent.success:
        record.successes++;
        record.score =
            (record.score + 8).clamp(PlaybackHealthRecord.minScore, PlaybackHealthRecord.maxScore);
        record.cooldownUntil = null;
      case PlaybackHealthEvent.slowBuffer:
        record.slowBuffers++;
        record.score =
            (record.score - 6).clamp(PlaybackHealthRecord.minScore, PlaybackHealthRecord.maxScore);
      case PlaybackHealthEvent.failed:
        record.failures++;
        record.score =
            (record.score - 20).clamp(PlaybackHealthRecord.minScore, PlaybackHealthRecord.maxScore);
        record.cooldownUntil = now.add(failureCooldown);
    }
    prune(now: now);
  }

  /// 某条线路的健康分；没有记录时返回默认分。
  int scoreOf(String key) =>
      _records[key]?.score ?? PlaybackHealthRecord.defaultScore;

  bool isCoolingDown(String key, {DateTime? at}) =>
      _records[key]?.coolingDownAt(at ?? _clock()) ?? false;

  /// 按健康分排序：冷却中的排最后，其余按分数降序；同分保持入参顺序。
  List<T> rankLines<T>(List<T> lines, String Function(T) keyOf) {
    final now = _clock();
    final indexed = <(int, T)>[
      for (var i = 0; i < lines.length; i++) (i, lines[i]),
    ];
    indexed.sort((a, b) {
      final aKey = keyOf(a.$2);
      final bKey = keyOf(b.$2);
      final aCool = _records[aKey]?.coolingDownAt(now) ?? false;
      final bCool = _records[bKey]?.coolingDownAt(now) ?? false;
      if (aCool != bCool) return aCool ? 1 : -1;
      final byScore = scoreOf(bKey).compareTo(scoreOf(aKey));
      if (byScore != 0) return byScore;
      return a.$1.compareTo(b.$1);
    });
    return <T>[for (final item in indexed) item.$2];
  }

  /// 淘汰超过 [retention] 未更新的记录，并裁剪到 [maxEntries]（保留高分）。
  void prune({DateTime? now}) {
    final at = now ?? _clock();
    _records.removeWhere(
      (_, record) => at.difference(record.updatedAt) > retention,
    );
    if (_records.length <= maxEntries) return;
    final ordered = _records.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : b.updatedAt.compareTo(a.updatedAt);
      });
    final keep = ordered.take(maxEntries).map((r) => r.key).toSet();
    _records.removeWhere((key, _) => !keep.contains(key));
  }

  void clear() => _records.clear();

  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final entry in _records.entries) entry.key: entry.value.toJson(),
      };

  void loadFromJson(Map<String, dynamic> json) {
    _records.clear();
    json.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        _records[key] = PlaybackHealthRecord.fromJson(key, value);
      }
    });
    prune();
  }
}
