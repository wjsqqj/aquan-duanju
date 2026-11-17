/// 纵向滑动调音量的纯计算。
///
/// 用户实测的 bug：全屏右半屏上下滑，无论方向都显示 100%。根因是起始音量
/// `_dragStartVolume` 用 `??=` 缓存后，**每次手势结束都没有清空**；一旦起点是
/// 100，向下滑算出 >100 被 clamp 成 100，向上滑又从同一份陈旧起点继续算。
/// 这里把「起点 + 增量」做成纯函数，并要求调用方每次手势重新取起点。
library;

/// 每滑动 2 逻辑像素改 1% 音量（沿用原实现口径）。
const double kVolumeDragSensitivity = 2;

/// 从 [startVolume] 起算手势音量：上滑（[dy] < 0）增大，下滑减小。
double volumeFromDrag(
  double startVolume,
  double dy, {
  double sensitivity = kVolumeDragSensitivity,
}) {
  if (sensitivity <= 0) return startVolume.clamp(0, 100).toDouble();
  return (startVolume - dy / sensitivity).clamp(0.0, 100.0).toDouble();
}
