/// 下一章预取的**纯调度组件**（design.md §3）：只管「何时触发 / 去重 / 并发 /
/// 世代」，不认识 `AquaApi` / `TtsComposer` / `SharedPreferences` —— 具体取什么
/// 由宿主的 `work` 闭包提供（TTS 版预合成落盘、音轨版 audioStream，见 §4）。
///
/// 为什么并发必须是 1：Edge 每个 chunk 都走一条**全新的 WSS 连接**，预取与当前
/// 播放的合成请求叠加等于自找限流（research `edge-upstream-protocol.md` §10.10
/// 的连接成本结论）。所以 `pump` 在跑期间再被调用直接返回，不排队、不叠加。
///
/// 为什么失败静默且不写 `_done`：预取是锦上添花——失败不能影响当前播放（PRD），
/// 但下一次越过阈值还应能重试，所以只有成功才记去重（design §3）。
library;

/// 阈值触发 + 去重 + 并发 1 + 世代丢弃的预取调度器。
class ChapterPrefetcher {
  ChapterPrefetcher({
    this.triggerRatioPercent = 35,
    this.triggerRemaining = const Duration(seconds: 180),
  });

  /// 触发比例：`position >= total * triggerRatioPercent%`。
  final int triggerRatioPercent;

  /// 触发剩余：`total - position <= triggerRemaining`。两条件**先满足者**生效。
  final Duration triggerRemaining;

  /// 正在跑的 taskId；并发 1 的闸门（null = 空闲）。
  String? _runningTaskId;

  /// 成功预取过的 taskId 去重集。
  final Set<String> _done = <String>{};

  /// 是否有任务在跑（宿主接线时可用于诊断，测试用它锁并发 1）。
  bool get isRunning => _runningTaskId != null;

  /// 到阈值了吗？——纯函数判定，不含副作用；通过则宿主再调 [pump]。
  ///
  /// `total <= 0`（时长未知）**不触发**：此时 `0 - position` 是负数恒
  /// `<= triggerRemaining`、`0 * 35%` 恒被任意 position 越过，两个条件都失去
  /// 依据——那才是「误触发」（章刚开播就发请求）。等宿主拿到真实时长后
  /// 下一次 tick 自然按正常两条件判定。
  bool shouldTrigger({
    required String taskId,
    required Duration position,
    required Duration total,
  }) {
    if (_runningTaskId == taskId || _done.contains(taskId)) return false;
    if (total <= Duration.zero) return false;
    final double ratio = triggerRatioPercent / 100.0;
    return position >= total * ratio || total - position <= triggerRemaining;
  }

  /// 执行一次预取。语义（design §3）：
  /// - 并发 1：已有任务在跑 → 直接返回（不排队）；
  /// - [work] 成功且 `isCurrent(epoch)` 仍为真 → 记入 `_done`；
  /// - 世代过期（切章/停止/换音色后迟到）→ 静默丢弃，不记 `_done` 也不抛；
  /// - [work] 抛任何异常 → 静默吞掉、不记 `_done`（下次可重试）、不影响播放。
  Future<void> pump({
    required String taskId,
    required int epoch,
    required bool Function(int epoch) isCurrent,
    required Future<void> Function() work,
  }) async {
    if (_runningTaskId != null) return; // 并发 1：在跑就丢弃本次请求
    if (_done.contains(taskId)) return; // 成功预取过：去重
    _runningTaskId = taskId;
    try {
      await work();
      // await 之后必须复核世代：迟到的成功结果同样作废（不写 _done），
      // 否则换音色后旧的"已预取"记录会挡住新音色的真实预取。
      if (isCurrent(epoch)) _done.add(taskId);
    } catch (_) {
      // 静默：预取失败不许打扰播放（含 TtsException——组件不认识具体异常类型，
      // 也不该认识；缓存键/坏项删除由宿主 work 闭包按 listen-tts-contract 处理）。
    } finally {
      _runningTaskId = null;
    }
  }

  /// 清空成功去重集。**宿主在 `close()` / 换音色 / 换引擎时调用**——组件自己
  /// 不认识这些事件。缓存键里含音色/引擎，但本组件的去重集不含，两处必须
  /// 一起失效，否则会误命中旧音色的"已预取"记录（design §3）。
  void invalidate() => _done.clear();
}
