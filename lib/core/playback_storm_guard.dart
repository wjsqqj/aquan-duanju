/// 播放错误风暴限流器（纯逻辑，[player_screen._onPlaybackError] 集成方执行动作）。
///
/// 现场（2026-11-20 PC 闪退取证）：切集后 mpv 拿错密钥解 CENC 音频，每个
/// 失败的 AAC 帧都报一条 `Error decoding audio`，每秒数百条错误事件——
/// 逐条记录会把日志/诊断缓冲刷爆，逐次决策会把换线预算瞬间耗尽。
///
/// 判定规则：**相同** raw 文本在 1 秒滑动窗口内第 [threshold] 次及以后命中
/// 视为风暴；不同文本各记各的桶，互不干扰（换线后换 URL 换错误文案，
/// 新线路的正常重试不该被上一条线路的风暴误伤）。窗口内的命中停低于阈值
/// 后自动恢复正常处理，无需显式解除。
class PlaybackStormGuard {
  /// 风暴判定窗口。
  static const Duration window = Duration(seconds: 1);

  /// 窗口内第几次同文本命中触发风暴。
  static const int threshold = 3;

  final Map<String, List<DateTime>> _hits = {};
  int _suppressed = 0;
  int _lastStormHits = 0;

  /// 本次会话被吞掉（风暴命中）的错误总条数；聚合日志用。
  int get suppressedCount => _suppressed;

  /// 最近一次风暴触发时窗口内的命中条数（含触发那次），聚合日志用。
  int get lastStormHits => _lastStormHits;

  /// 相同 [raw] 在窗口内的第 [threshold] 次及以后命中返回 true（=风暴，
  /// 调用方应停止逐条记录/决策，改走聚合收尾）。
  bool shouldSuppress(String raw, DateTime now) {
    final hits = (_hits[raw] ??= <DateTime>[])..add(now);
    hits.removeWhere((t) => now.difference(t) > window);
    if (hits.length < threshold) return false;
    _lastStormHits = hits.length;
    _suppressed++;
    return true;
  }

  /// 成功开播（新线路/新集）时调用：换线后的错误是新一轮证据，重新计数。
  void reset() {
    _hits.clear();
    _suppressed = 0;
    _lastStormHits = 0;
  }
}
