import 'dart:async';

/// 等待播放器「真正出画」：首个正播放位置即视为可 seek。
///
/// 背景：mpv 的 `open()` 返回时文件往往还没 loaded，紧接着的 `seek()` 会被
/// 丢弃（实测每次带进度续播都要靠位置事件的补救逻辑再 seek 一次，起播先停在
/// 0s 再跳到目标）。仅等 `duration > 0` / `playing == true` 仍不够——这两个
/// 信号都可能早于解码器真正跑起来；位置开始前进才是可靠的「可 seek」判据。
///
/// 超时（默认 2s）返回 false，调用方按原行为直接 seek——网络慢时仍由位置
/// 事件侧的兜底补救。
///
/// 无论成功还是超时，返回前都会取消订阅与定时器，不留 listener。
Future<bool> waitForPlaybackReady({
  required Stream<Duration> position,
  Duration timeout = const Duration(seconds: 2),
}) {
  final completer = Completer<bool>();
  void finish(bool ok) {
    if (!completer.isCompleted) completer.complete(ok);
  }

  // position 是 broadcast stream，多订阅安全（播放页自身也在监听）。
  StreamSubscription<Duration>? positionSub;
  Timer? timer;
  positionSub = position.listen((p) {
    if (p > Duration.zero) finish(true);
  });
  timer = Timer(timeout, () => finish(false));
  // cancel() 返回 Future，这里不需要 await；whenComplete 在回调之后才让
  // 调用方拿到结果，因此返回时订阅已经摘掉。
  return completer.future.whenComplete(() {
    timer?.cancel();
    positionSub?.cancel();
  });
}
