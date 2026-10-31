/// 听书时间文案：两处 UI（独立听书页、阅读页听书条）共用一份，避免出现两种写法。
library;

/// `mm:ss`（超过一小时就变成 `62:05`，不截断小时 —— 音轨可能很长）。
///
/// 负数一律当 0：位置事件偶尔会比 0 早一帧（seek 回章首），不能让 UI 出现 `-1:-5`。
String formatListenTime(Duration position) {
  final total = position.isNegative ? 0 : position.inSeconds;
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
