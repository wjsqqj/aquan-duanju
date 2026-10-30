/// 慢缓冲判定器：只回答「这次卡顿够不够格换源」，不碰播放器。
///
/// 参考 tvbox `PlaybackBufferMonitor` / `LivePlaybackWatchdog` 的分类方式，
/// 把「卡」拆成四种互不重叠的形态，各自有独立阈值：
///
/// | 形态 | 判据 | 典型原因 |
/// |---|---|---|
/// | [BufferIssue.startupTimeout] | 起播 15s 内没进入 playing | 源站慢/地址失效 |
/// | [BufferIssue.longBuffer] | 单次 buffering ≥ 8s | 线路带宽不够 |
/// | [BufferIssue.frequentBuffer] | 60s 内 ≥ 3 次 buffering | 线路抖动 |
/// | [BufferIssue.accumulatedBuffer] | 120s 内累计 ≥ 30s | 整体质量差 |
///
/// 判定命中后进入 60s 冷却，避免一次卡顿被反复上报；seek 后 5s 内不计入，
/// 因为换线/拖进度本来就会短暂缓冲。
class PlaybackBufferMonitor {
  PlaybackBufferMonitor({
    DateTime Function()? clock,
    this.startupTimeout = const Duration(seconds: 15),
    this.longBuffer = const Duration(seconds: 8),
    this.frequentWindow = const Duration(seconds: 60),
    this.frequentCount = 3,
    this.accumulateWindow = const Duration(seconds: 120),
    this.accumulateTotal = const Duration(seconds: 30),
    this.seekGrace = const Duration(seconds: 5),
    this.cooldown = const Duration(seconds: 60),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  final Duration startupTimeout;
  final Duration longBuffer;
  final Duration frequentWindow;
  final int frequentCount;
  final Duration accumulateWindow;
  final Duration accumulateTotal;
  final Duration seekGrace;
  final Duration cooldown;

  DateTime? _openedAt;
  DateTime? _firstPlayingAt;
  DateTime? _bufferingSince;
  DateTime? _lastSeekAt;
  DateTime? _lastVerdictAt;

  /// 每次 buffering 的起始时间（窗口过滤用）。
  final List<DateTime> _bufferStarts = <DateTime>[];

  /// 已结束的缓冲区间（累计时长用）。
  final List<_Interval> _bufferIntervals = <_Interval>[];

  bool get isBuffering => _bufferingSince != null;

  /// 起播开始（`open` 被调用）。重复调用只在未起播时重置计时。
  void onOpen() {
    _openedAt = _clock();
    _firstPlayingAt = null;
  }

  /// 真正进入播放（出画面/出声音）。
  void onPlaying() {
    _openedAt ??= _clock();
    _firstPlayingAt ??= _clock();
    _endBuffering(_clock());
  }

  /// buffering 状态变化。
  void onBuffering(bool buffering) {
    final now = _clock();
    if (buffering) {
      if (_bufferingSince != null) return;
      _bufferingSince = now;
      _bufferStarts.add(now);
      return;
    }
    _endBuffering(now);
  }

  /// 用户/播放器触发了 seek：给一段宽限期。
  void onSeek() => _lastSeekAt = _clock();

  /// 播放器报错（解码/网络）：直接判失败，调用方据此换线。
  void onError() {
    _lastVerdictAt = _clock();
  }

  /// 周期调用（建议 1s 一次）。命中返回判定，否则 null。
  BufferVerdict? tick() {
    final now = _clock();

    // 冷却期内不重复上报。
    final lastVerdict = _lastVerdictAt;
    if (lastVerdict != null && now.difference(lastVerdict) < cooldown) {
      return null;
    }

    // 1) 起播超时。
    final openedAt = _openedAt;
    if (openedAt != null &&
        _firstPlayingAt == null &&
        now.difference(openedAt) >= startupTimeout) {
      return _emit(
        BufferIssue.startupTimeout,
        now,
        '起播 ${now.difference(openedAt).inSeconds}s 未进入播放',
      );
    }

    // seek 宽限期：刚拖过进度，缓冲是预期的。
    final lastSeek = _lastSeekAt;
    final inSeekGrace =
        lastSeek != null && now.difference(lastSeek) < seekGrace;

    // 2) 单次长缓冲。
    final since = _bufferingSince;
    if (!inSeekGrace && since != null) {
      final duration = now.difference(since);
      if (duration >= longBuffer) {
        return _emit(
          BufferIssue.longBuffer,
          now,
          '单次缓冲 ${duration.inSeconds}s',
        );
      }
    }

    _prune(now);

    // 3) 频繁缓冲。
    if (!inSeekGrace && _bufferStarts.length >= frequentCount) {
      return _emit(
        BufferIssue.frequentBuffer,
        now,
        '${frequentWindow.inSeconds}s 内缓冲 ${_bufferStarts.length} 次',
      );
    }

    // 4) 累计缓冲。
    if (!inSeekGrace) {
      var total = Duration.zero;
      for (final interval in _bufferIntervals) {
        total += interval.overlap(now.subtract(accumulateWindow), now);
      }
      if (since != null) {
        final tailStart =
            since.isAfter(now.subtract(accumulateWindow)) ? since : now.subtract(accumulateWindow);
        total += now.difference(tailStart);
      }
      if (total >= accumulateTotal) {
        return _emit(
          BufferIssue.accumulatedBuffer,
          now,
          '${accumulateWindow.inSeconds}s 内累计缓冲 ${total.inSeconds}s',
        );
      }
    }

    return null;
  }

  /// 换源后重置：新线路重新计时，但保留冷却（避免立刻对同一线路再报）。
  void resetForNewLine() {
    _openedAt = _clock();
    _firstPlayingAt = null;
    _bufferingSince = null;
    _bufferStarts.clear();
    _bufferIntervals.clear();
    _lastSeekAt = null;
  }

  /// 完全重置（含冷却）。
  void reset() {
    resetForNewLine();
    _lastVerdictAt = null;
  }

  BufferVerdict _emit(BufferIssue issue, DateTime now, String detail) {
    _lastVerdictAt = now;
    // 清掉已上报的窗口数据，避免下一次 tick 立刻再次命中。
    _bufferStarts.clear();
    _bufferIntervals.clear();
    _bufferingSince = null;
    return BufferVerdict(issue, detail);
  }

  void _endBuffering(DateTime now) {
    final since = _bufferingSince;
    if (since == null) return;
    _bufferIntervals.add(_Interval(since, now));
    _bufferingSince = null;
  }

  void _prune(DateTime now) {
    final windowStart = now.subtract(
      frequentWindow > accumulateWindow ? frequentWindow : accumulateWindow,
    );
    _bufferStarts.removeWhere((at) => at.isBefore(windowStart));
    _bufferIntervals.removeWhere((i) => i.end.isBefore(windowStart));
  }
}

/// 判定结果。
class BufferVerdict {
  const BufferVerdict(this.issue, this.detail);

  final BufferIssue issue;
  final String detail;

  /// 给用户看的短句。
  String get message => switch (issue) {
        BufferIssue.startupTimeout => '起播太慢，建议换源',
        BufferIssue.longBuffer => '缓冲时间过长，建议换源',
        BufferIssue.frequentBuffer => '频繁卡顿，建议换源',
        BufferIssue.accumulatedBuffer => '画质不流畅，建议换源',
      };

  @override
  String toString() => 'BufferVerdict(${issue.name}, $detail)';
}

/// 卡顿形态。
enum BufferIssue {
  startupTimeout,
  longBuffer,
  frequentBuffer,
  accumulatedBuffer,
}

class _Interval {
  const _Interval(this.start, this.end);

  final DateTime start;
  final DateTime end;

  Duration overlap(DateTime from, DateTime to) {
    final begin = start.isAfter(from) ? start : from;
    final finish = end.isBefore(to) ? end : to;
    if (!finish.isAfter(begin)) return Duration.zero;
    return finish.difference(begin);
  }
}
