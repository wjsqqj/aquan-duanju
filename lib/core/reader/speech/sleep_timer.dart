/// 定时关闭（Sleep Timer）的**纯决策组件**（design.md §2）。
///
/// 为什么做成「宿主驱动、组件不起 Timer」：
/// - 工程里有**两条并行播放路径**（`ReaderSpeechController` 与 `book_audio_screen`
///   自带的 `_engine`），两边都要接同一个定时逻辑；组件一旦自己起 `Timer` 或读
///   `BuildContext`/SharedPreferences，就必然长出不止一份实现（PRD 硬约束）。
/// - 脱屏可测：所有判定只依赖显式传入的 `tick` 参数，单测不需要任何播放环境。
///
/// **计时基准是媒体时间轴 `position`**：倒计时由「武装后第一次 tick 的 position」
/// 加目标分钟数推算（零点取首次 tick，因为浮层 `setMode` 时组件拿不到播放位，
/// 而宿主加一个「武装时传 position」的参数反而扩大接线面）。暂停时 position
/// 不推进、宿主也不 tick，所以**暂停天然不计时** —— 这是选择媒体时间轴而不是
/// 墙钟的根本原因；[clockMs] 保留以对齐 design §2 的签名，但组件**刻意不用它做
/// 倒计时**：用墙钟倒计时会在暂停期间继续扣时间，是错误行为。
///
/// 本组件**绝不读写** `listen.autoNext` 等任何持久化偏好：「本章播完停」只对当次
/// 生效（PRD），宿主通过 [consumeSleepSuppressAutoNext] 查询即可。
library;

/// 定时模式。
enum SleepMode { off, minutes, endOfChapter }

/// 到点停止的原因。
enum SleepStopReason { timedOut, chapterEnd }

/// 时长档位（分钟）。档位外的值也接受（用户可自定义），只做展示排序用。
const List<int> kSleepMinutePresets = <int>[10, 15, 30, 45, 60, 90];

/// 句尾守卫的宽限上限：句尾离到点超过这个值就直接停，不再等。
///
/// 为什么是 30s：让用户按了定时却迟迟不停，比切半句更糟（design §2）。
const Duration kSleepGuardMaxExtra = Duration(seconds: 30);

/// [SleepTimer.tick] 的判决：要不要现在就停、为什么停。
class SleepDecision {
  const SleepDecision({required this.stop, this.reason});

  /// 不停（未到点、或到点但正等句尾）。
  const SleepDecision.pass() : stop = false, reason = null;

  final bool stop;
  final SleepStopReason? reason;
}

/// 定时关闭状态机：`setMode` 武装，宿主在**每次播放位置更新**时调 [tick]。
class SleepTimer {
  SleepTimer({required this.clockMs});

  /// 注入的毫秒时钟。见文件头：组件不用它倒计时，保留是对齐 design 签名并
  /// 给宿主留诊断/埋点用途（公有字段不会被误报 unused）。
  final int Function() clockMs;

  SleepMode _mode = SleepMode.off;
  int _minutes = 0;

  /// 武装后的零点 position（媒体时间轴）；首次 tick 时落定。
  Duration? _basePosition;

  /// 最近一次 tick 的 position，[remaining] 的推算依据。
  Duration? _lastPosition;

  /// 「本章播完停」已 fire、宿主还没消费的连播抑制位。
  bool _suppressAutoNext = false;

  SleepMode get mode => _mode;

  /// 仅 [SleepMode.minutes] 有意义；其余模式恒为 0。
  int get minutes => _mode == SleepMode.minutes ? _minutes : 0;

  /// 已武装（等待生效）。注意 minutes 模式武装后、首次 tick 前 [remaining]
  /// 还是 null —— 那会儿还没有媒体位置基准。
  bool get armed => _mode != SleepMode.off;

  /// 剩余时长（媒体时间轴）。未武装 / 还没拿到零点 position / endOfChapter
  /// 模式一律返回 null —— 显示文案只允许来自这里，两处 UI 不各自换算。
  Duration? get remaining {
    if (_mode != SleepMode.minutes) return null;
    final Duration? base = _basePosition;
    final Duration? last = _lastPosition;
    if (base == null || last == null) return null;
    final Duration target = base + Duration(minutes: _minutes);
    final Duration left = target - last;
    return left > Duration.zero ? left : Duration.zero;
  }

  /// 取消定时立即生效（[armed] 变 false、基准清空），并可随时重新武装。
  ///
  /// 越界容错：`minutes` 不在 [kSleepMinutePresets] 内也接受（自定义时长）；
  /// `minutes <= 0` 视为取消（等同 off），不接受一个「立刻就会停」的计时档。
  void setMode(SleepMode mode, {int? minutes}) {
    if (mode == SleepMode.minutes) {
      final int m = minutes ?? 0;
      if (m <= 0) {
        setMode(SleepMode.off);
        return;
      }
      _minutes = m;
    } else if (mode == SleepMode.off) {
      _minutes = 0;
    }
    _mode = mode;
    _basePosition = null;
    _lastPosition = null;
    _suppressAutoNext = false;
  }

  /// 「本章播完停」fire 后为 true；**读一次即清**，保证抑制只作用于 fire 当次
  /// 的 `completed` 事件 —— 若宿主当次没消费（例如已在别处接管连播），后续
  /// 章节的连播不能再被隔空误伤。
  bool consumeSleepSuppressAutoNext() {
    final bool value = _suppressAutoNext;
    _suppressAutoNext = false;
    return value;
  }

  /// 只读窥视（不消费），给 UI/测试用。
  bool get sleepSuppressAutoNext => _suppressAutoNext;

  /// 每次播放位置更新调用一次。宿主**只在 playing 时**调用；暂停不调用即
  /// 不计时（基准是 position，不是墙钟）。
  ///
  /// [sentenceEndMs] 为 null 表示拿不到句边界（平台音轨路径）→ 到点只能立即停，
  /// 宿主应在 UI 说明「该音源只能整点停止」（design §2）。
  SleepDecision tick({
    required Duration position,
    Duration? sentenceEndMs,
    bool chapterCompleted = false,
  }) {
    _lastPosition = position;
    if (_mode == SleepMode.off) return const SleepDecision.pass();

    // 本章播完停：只在 completed 边沿 fire，一次性，随后自动落回 off。
    if (_mode == SleepMode.endOfChapter) {
      if (!chapterCompleted) return const SleepDecision.pass();
      _mode = SleepMode.off;
      _minutes = 0;
      _basePosition = null;
      _suppressAutoNext = true; // 宿主在 completed 分支先消费再决定连播
      return const SleepDecision(
        stop: true,
        reason: SleepStopReason.chapterEnd,
      );
    }

    // 定时分钟模式：首次 tick 落定媒体时间轴零点。
    _basePosition ??= position;
    final Duration target = _basePosition! + Duration(minutes: _minutes);
    if (position < target) return const SleepDecision.pass();

    // 到点。句尾守卫：宽限窗口内等到句尾再停，避免把半句掐断。
    final Duration? endMs = sentenceEndMs;
    if (endMs != null) {
      final Duration extra = endMs - position;
      if (extra > Duration.zero && extra <= kSleepGuardMaxExtra) {
        return const SleepDecision.pass(); // 等这句念完（后续 tick 再判）
      }
      // extra <= 0：句尾数据已过期（这句实际早念完了）→ 立即停；
      // extra > 30s：等下去只会让用户觉得「定时没生效」→ 立即停。
    }
    // 与 endOfChapter 一致：fire 后自动落回 off，防止用户恢复播放时 position
    // 仍 >= target 被立刻再停、永远播不动。监听 autoNext 与此无关——本组件不碰。
    _mode = SleepMode.off;
    _minutes = 0;
    _basePosition = null;
    return const SleepDecision(stop: true, reason: SleepStopReason.timedOut);
  }
}
