/// 定时到点的音量淡出：把「定时关闭」从硬切改成 3 秒线性降音。
///
/// 为什么是播放器音量而不是音频渐变：定时是一次性事件，硬切会把刚要睡着的人直接
/// 惊醒；而**改音频字节**（往章尾塞渐变静音）会动「字节 ÷ 码率 = 时间」这条不变式，
/// 除非同步平移全部时间点。音量斜坡是唯一不碰时间轴的做法。
///
/// 两条铁律：
/// 1. **结束后必须恢复满音量**：淡出改的是播放器状态，不属于用户偏好；不恢复的话
///    下次点播放会「没声音」，且极难归因。
/// 2. **可取消**：淡出期间用户可能切章/关页，[isCurrent] 返回 false 时立刻停手，
///    由调用方继续走它自己的收尾。
library;

/// 默认淡出时长（毫秒）。3 秒足够让人有"渐弱"的感知，又不至于觉得定时不准。
const int kSleepFadeOutMs = 3000;

/// 默认淡出步数（10 步 × 300ms）。步数越多越平滑，但每步都是一次播放器调用。
const int kSleepFadeOutSteps = 10;

/// 跑一次淡出。返回 false 表示中途被取消（调用方仍应走暂停与音量恢复）。
///
/// [sleep] 与 [setVolume] 都可注入：单测既不该真等 3 秒，也不该碰真播放器。
Future<bool> runVolumeFadeOut({
  double from = 1.0,
  int durationMs = kSleepFadeOutMs,
  int steps = kSleepFadeOutSteps,
  required Future<void> Function(double volume) setVolume,
  Future<void> Function(Duration duration)? sleep,
  bool Function()? isCurrent,
}) async {
  if (durationMs <= 0 || steps <= 0) return isCurrent?.call() ?? true;
  final wait = sleep ?? Future<void>.delayed;
  final start = from.isNaN ? 1.0 : from.clamp(0.0, 1.0).toDouble();
  final base = start <= 0 ? 1.0 : start;
  final stepMs = durationMs ~/ steps;
  for (var i = 1; i <= steps; i++) {
    if (!(isCurrent?.call() ?? true)) return false;
    final volume = base * (1 - i / steps);
    await setVolume(volume < 0 ? 0 : volume);
    await wait(Duration(milliseconds: stepMs));
  }
  return isCurrent?.call() ?? true;
}
