/// completed（自然播完）事件的可信性判定（纯逻辑，[player_screen] 集成方
/// 执行动作）。
///
/// 背景（2026-11-15 回归）：60688de 把真播完判定改成唯一硬门禁
/// `watchedSec >= 45`，但短剧单集只有 ~1 分钟、续播位置常在片尾附近
/// （51s 的集从 50s 续播只真实前进 1s 就合法播完），watched 永远凑不够 45s
/// → 合法播完被误判「流异常中断」→ 换线死循环 → 自动连播全挂。
///
/// 谎报小时长无法从播放器内部信号识破（播 20s 报 20s 与合法 20s 集不可
/// 区分），必须用**外部下限**交叉验证，按可用性降级：
/// 1. 服务端时长 [serverDurationSec]（红果 SDK 上游下发，>0 才用）；
/// 2. 续播下限 [resumeLowerBoundSec]（本集开播断点 >2s 才用：此前真实
///    播放到过该位置，真时长必然 ≥ 它——续播近片尾的正证据）；
/// 3. 两者皆缺（新开播 + 服务端无真值）退回 45s 硬门禁（语义同 60688de）。
library;

/// completed 的**时长真值**验证（不含「到达终点」——片尾跳过路径在终点前
/// 就触发，不能要求位置贴着终点）。
bool durationTruthOk({
  required double durationSec,
  required double watchedSec,
  int serverDurationSec = 0,
  double resumeLowerBoundSec = 0,
}) {
  if (durationSec <= 0) return false;
  if (serverDurationSec > 0) return durationSec >= serverDurationSec - 3;
  if (resumeLowerBoundSec > 2) return durationSec >= resumeLowerBoundSec - 1;
  return watchedSec >= 45;
}

/// completed 是否可信（真播完）= 三重独立证据全部成立：
/// - 时长真值（[durationTruthOk]，防谎报小时长绕过）；
/// - 位置真实到达终点（位置由播放器真实时钟推进，到不了终点 = 中途夭折；
///   3s 容差覆盖末帧停滞）；
/// - 确实播过（watched ≥0.5s 或位置 ≥3s——排除「open 即 completed」；
///   pos ≥3 放行用户拖到结尾的显式意图）。
bool trustPlaybackCompletion({
  required double positionSec,
  required double durationSec,
  required double watchedSec,
  int serverDurationSec = 0,
  double resumeLowerBoundSec = 0,
}) {
  if (!durationTruthOk(
    durationSec: durationSec,
    watchedSec: watchedSec,
    serverDurationSec: serverDurationSec,
    resumeLowerBoundSec: resumeLowerBoundSec,
  )) {
    return false;
  }
  if (positionSec < durationSec - 3) return false;
  if (watchedSec < 0.5 && positionSec < 3) return false;
  return true;
}
