/// 播放失败自动换线规划（xiugou-tv line_switch_planner 同语义，实现原创）。
///
/// 两级回退：先换同源的下一条线路，线路尽则换下一个可用源（健康分降序）。
/// 早期窗口（15s）内位置正常前进即取消换行——播放其实已经起来了，失败是误报；
/// epoch 防旧回调改写新会话（换线动作只属于发起它那一代）。
class LineSwitchPlanner {
  LineSwitchPlanner({required this.candidates, this.earlyWindowMs = 15000});

  /// 候选按优先级排好（线路在前、源在后；健康分降序）。
  final List<SwitchCandidate> candidates;
  final int earlyWindowMs;

  int _epoch = 0;
  int _activeIndex = -1;
  int? _pendingPositionMs;
  DateTime? _pendingSince;
  bool _disposed = false;

  /// 当前生效的代数（外部回调必须携带它，重放时校验）。
  int get epoch => _epoch;

  /// 播放失败：调度下一次换线；返回要切换到的候选（null = 无可换）。
  ///
  /// [positionMs] 是失败时播放位置；换线应从该位置续播。
  SwitchDecision? onPlaybackFailed(int positionMs) {
    if (_disposed) return null;
    final nextIndex = _activeIndex + 1;
    if (nextIndex >= candidates.length) return null;
    _epoch++;
    _activeIndex = nextIndex;
    _pendingPositionMs = positionMs;
    _pendingSince = DateTime.now();
    final c = candidates[nextIndex];
    return SwitchDecision(
        candidate: c, resumeAtMs: positionMs, epoch: _epoch);
  }

  /// 播放位置更新：早期窗口内位置前进即取消挂起的换线（误报），
  /// 并把游标复位——播放已健康，下次失败从最优候选重新换起。
  void onPositionChanged(int positionMs, {required bool playing}) {
    if (_disposed) return;
    final pendingSince = _pendingSince;
    if (pendingSince == null) return;
    if (!playing) return;
    final inWindow =
        DateTime.now().difference(pendingSince).inMilliseconds <= earlyWindowMs;
    final advanced = _pendingPositionMs == null ||
        positionMs > _pendingPositionMs! + 500;
    if (inWindow && advanced) {
      _reset();
    }
  }

  /// 换线动作已执行（换过去的那条现在算「当前」）：清挂起状态，游标留在原地，
  /// 该条再失败才会换到再下一条。
  void consume(int calledEpoch) {
    if (calledEpoch == _epoch) {
      _pendingPositionMs = null;
      _pendingSince = null;
    }
  }

  void _reset() {
    _activeIndex = -1;
    _pendingPositionMs = null;
    _pendingSince = null;
  }

  void dispose() => _disposed = true;
}

/// 一条换线候选：源内线路或备用源。
class SwitchCandidate {
  const SwitchCandidate({required this.key, this.kind = SwitchKind.line});
  final String key;
  final SwitchKind kind;
}

enum SwitchKind { line, source }

/// 一次换线决定：切到谁、从哪里续播、属于哪一代。
class SwitchDecision {
  const SwitchDecision({
    required this.candidate,
    required this.resumeAtMs,
    required this.epoch,
  });
  final SwitchCandidate candidate;
  final int resumeAtMs;
  final int epoch;
}
