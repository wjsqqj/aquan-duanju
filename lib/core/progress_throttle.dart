/// 播放进度落盘节流器（纯逻辑，便于单测）。
///
/// 与「墙钟每 N 秒写一次」相比，按**播放位置差**节流有两个好处：
/// - 暂停 / 拖动进度条时不会空写；
/// - 重载后 seek 过渡期的事件不会被当成新进度，[floor] 在位置越过基线前
///   一律拒绝写入，避免把断点覆盖成 0 或更小的值。
class ProgressWriteThrottle {
  ProgressWriteThrottle({this.interval = const Duration(seconds: 5)});

  final Duration interval;

  Duration? _last;
  Duration? _floor;

  /// 开始跟踪一条新记录。
  ///
  /// [baseline] 为已落盘位置（换集 / 恢复历史时传入）；
  /// [floor] 为位置下限：低于它的事件忽略，越过一次后自动解除。
  void reset({Duration? baseline, Duration? floor}) {
    _last = baseline;
    _floor = floor;
  }

  /// 该位置是否值得写盘；返回 true 时内部基线同步推进。
  ///
  /// 位置为 0 或负数时不写（避免「刚打开就写 0」覆盖断点）。
  bool shouldWrite(Duration position) {
    if (position <= Duration.zero) return false;
    final floor = _floor;
    if (floor != null) {
      if (position < floor) return false;
      _floor = null;
    }
    final last = _last;
    if (last == null) {
      _last = position;
      return true;
    }
    if ((position - last).abs() < interval) return false;
    _last = position;
    return true;
  }

  /// 外部强制写盘后同步基线（暂停 / 完成 / 退出）。
  void markWritten(Duration position) {
    _last = position;
  }

  void clear() {
    _last = null;
    _floor = null;
  }
}
