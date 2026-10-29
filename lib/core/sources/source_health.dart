/// 源被动健康追踪：播放/搜索过程中顺带采集，无需独立测速。
///
/// 评分与冷却语义（tvbox SourceHealthTracker 同公式）：
/// - 成功：EMA 延迟 `(avg*3+x)/4`；
/// - 搜索失败冷却 2 分钟，播放失败冷却 30 分钟；
/// - `score = successes*1000 − failures*500 − avgLatencyMs/10`。
class SourceHealthRecord {
  SourceHealthRecord({
    this.successes = 0,
    this.failures = 0,
    this.avgLatencyMs = 0,
    this.cooldownUntil = 0,
    this.lastError = '',
    this.lastUsedAt = 0,
  });

  factory SourceHealthRecord.fromJson(Map<String, dynamic> json) =>
      SourceHealthRecord(
        successes: json['successes'] as int? ?? 0,
        failures: json['failures'] as int? ?? 0,
        avgLatencyMs: (json['avgLatencyMs'] as num?)?.toDouble() ?? 0,
        cooldownUntil: json['cooldownUntil'] as int? ?? 0,
        lastError: json['lastError'] as String? ?? '',
        lastUsedAt: json['lastUsedAt'] as int? ?? 0,
      );

  /// 冷却时长（毫秒）：搜索失败短冷却，播放失败长冷却。
  static const int searchCooldownMs = 2 * 60 * 1000;
  static const int playCooldownMs = 30 * 60 * 1000;

  int successes;
  int failures;
  double avgLatencyMs;
  int cooldownUntil;
  String lastError;
  int lastUsedAt;

  /// 记录一次成功：EMA 平滑延迟，清除冷却。
  void recordSuccess(int latencyMs, {DateTime? now}) {
    successes++;
    avgLatencyMs = successes <= 1
        ? latencyMs.toDouble()
        : (avgLatencyMs * 3 + latencyMs) / 4;
    cooldownUntil = 0;
    lastError = '';
    lastUsedAt = (now ?? DateTime.now()).millisecondsSinceEpoch;
  }

  /// 记录一次失败：按 [playFailure] 区分冷却时长。
  void recordFailure(String reason,
      {bool playFailure = false, DateTime? now}) {
    failures++;
    final cooldown = playFailure ? playCooldownMs : searchCooldownMs;
    cooldownUntil =
        ((now ?? DateTime.now()).millisecondsSinceEpoch) + cooldown;
    lastError = reason;
    lastUsedAt = (now ?? DateTime.now()).millisecondsSinceEpoch;
  }

  /// 冷却期内不参与聚合搜索/自动换线。
  bool isCoolingDown([DateTime? now]) =>
      cooldownUntil > ((now ?? DateTime.now()).millisecondsSinceEpoch);

  /// 综合健康分：越大越优先（排序用，不直接给用户看）。
  int get score => successes * 1000 - failures * 500 - avgLatencyMs ~/ 10;

  Map<String, dynamic> toJson() => {
        'successes': successes,
        'failures': failures,
        'avgLatencyMs': avgLatencyMs,
        'cooldownUntil': cooldownUntil,
        if (lastError.isNotEmpty) 'lastError': lastError,
        'lastUsedAt': lastUsedAt,
      };
}
