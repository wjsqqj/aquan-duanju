/// 续播位置的确定规则。
///
/// 参考 `kaixinguo` / `kaixinguo-android` 的 `resumePoint()`：从历史断点起播时
/// 回退 3 秒。断点通常停在上一句台词中间，不回退会让用户每次续播都先听半句。
library;

/// 续播回退秒数。
const int kResumeRewindSeconds = 3;

/// 断点秒数 → 实际起播秒数（回退 [kResumeRewindSeconds]，最低 0）。
///
/// 传入的是**秒**（`HistoryEntry.position` 的单位），不做毫秒换算。
int resumePositionSeconds(num savedSeconds) {
  final seconds = savedSeconds.floor();
  if (seconds <= 0) return 0;
  if (seconds <= kResumeRewindSeconds) return 0;
  return seconds - kResumeRewindSeconds;
}
