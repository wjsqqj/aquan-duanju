/// 播放页长按手势的横向分区。
enum LongPressZone {
  /// 左 1/3：快退。
  rewind,

  /// 中 1/3：不响应。
  none,

  /// 右 1/3：快进。
  forward,
}

/// 播放页「空白处」单击/双击判定器：**按下**记时刻、抬手消费。
///
/// 为什么不用 `onDoubleTap`：DoubleTap 识别器会把手势竞技场里的指针 hold 到
/// `kDoubleTapTimeout`(300ms)，内层每个按钮的单击都被拖延，连点还会误触。
///
/// 为什么不在抬手（`onTap`）里自己比时间戳：那样量的是 up→up，会把第二次
/// 按下的按压时长算进间隔——200ms 间隔 + 80ms 按压就顶到 300ms 边界，
/// 慢一点的连点直接判不出来，用户看到的是「双击没反应」（11-17 实测）。
/// 所以按下时记时刻，抬手时只做消费。
class SurfaceTapArbiter {
  /// 双击窗口：两次「按下」之间允许的最大间隔（与系统双击口径一致）。
  static const Duration window = Duration(milliseconds: 350);

  /// 标成双击候选之后，抬手超过这个时长就不算双击了
  /// （那次按压已经变成拖动/长按，不该再触发全屏或暂停）。
  static const Duration pressLimit = Duration(seconds: 1);

  DateTime? _lastDownAt;
  DateTime? _armedDownAt;

  /// 记录一次按下：落在 [window] 内的第二下把它标成双击候选。
  void onDown(DateTime now) {
    final DateTime? last = _lastDownAt;
    if (last != null && now.difference(last) <= window) {
      _armedDownAt = now;
      // 成对消费：三连击的第三下不再算双击。
      _lastDownAt = null;
      return;
    }
    // 没接上上一击：之前挂起的候选作废。
    //
    // 候选只在「抬手」时消费，而抬手可能永远不来（那次按压变成了拖动快进或
    // 长按快退，手势被它们赢走，`onTap` 不触发）。不在这里清掉的话，候选会
    // 一直挂着，后面 1 秒内的普通单击就被误判成双击——移动端会突然暂停。
    _armedDownAt = null;
    _lastDownAt = now;
  }

  /// 抬手时问一句：这次点击是不是双击？问过即清账，一次点击只判定一次。
  bool consumeIsDoubleTap(DateTime now) {
    final DateTime? armed = _armedDownAt;
    _armedDownAt = null;
    return armed != null && now.difference(armed) <= pressLimit;
  }
}

/// 判断长按落点属于哪个分区。
///
/// 移动端双击已经让给「暂停/继续」，快进快退改成长按左右各三分之一；中间留空，
/// 避免用户想双击暂停却长按误跳。抽成纯函数是为了能单测 1/3、2/3 两个边界。
///
/// 11-17 起长按改为「2 倍速」后，播放页不再按分区分支；纯函数保留给电视端/
/// 自定义手势与既有测试。
LongPressZone longPressZoneAt({
  required double dx,
  required double width,
}) {
  if (width <= 0) return LongPressZone.none;
  final x = dx.clamp(0.0, width);
  if (x < width / 3) return LongPressZone.rewind;
  if (x > width * 2 / 3) return LongPressZone.forward;
  return LongPressZone.none;
}

/// 长按倍速的三态（对齐 kaixinguo-android 的 `DoubleSpeed`）。
enum HoldSpeedPhase {
  /// 未长按，按用户选定速率播放。
  off,

  /// 按住中：松手恢复 [HoldSpeedState.baseRate]。
  held,

  /// 已锁定：持续 2 倍速，直到下一次「按住 + 上滑」解除。
  locked,
}

/// 全屏右侧选集抽屉的边缘热区宽度（逻辑像素）。
///
/// 参考 `kaixinguo/view_player.go` 的 `episodesEdge()`：16px 薄条刚好塞进
/// 播放器右侧留白，不会明显抢走视频区域的鼠标操作。
const double kEdgePanelHotZoneWidth = 16;

/// 全屏右侧选集抽屉的底部避让高度（逻辑像素）。
///
/// 抽屉不再延伸到控制栏区域：进度条行 + 底栏按钮行的合计高度留出来，
/// 最后一行集数不被「播放中」的那排按钮遮住（用户实测反馈）。
const double kEdgePanelBottomInset = 104;

/// 鼠标进入右侧热区时是否弹出抽屉（手动关掉后需先离开热区再回来）。
bool edgePanelShouldOpen({required bool hoverEdge, required bool suppressed}) =>
    hoverEdge && !suppressed;

/// 鼠标离开热区与抽屉后是否收起（两者都不在才收，避免边界抖动）。
bool edgePanelShouldClose({
  required bool hoverEdge,
  required bool hoverPanel,
}) =>
    !hoverEdge && !hoverPanel;

/// 长按倍速状态机（纯逻辑，可单测）。
///
/// 使用方式：按下 [begin] → 移动 [drag]（累计位移）→ 松手 [release]。
/// 关键点：**只有 `off` 时才记录 `baseRate`**，锁定期间再按住不能把 2 倍速
/// 当成「用户选定速率」，否则解锁后会停在 2 倍速。
class HoldSpeedState {
  const HoldSpeedState({
    this.phase = HoldSpeedPhase.off,
    this.baseRate = 1,
    this.armed = false,
  });

  final HoldSpeedPhase phase;

  /// 长按前的用户选定速率（锁定期间保持不变）。
  final double baseRate;

  /// 本次按住是否已越过锁定/解锁阈值。
  final bool armed;

  /// 长按倍速档位。
  static const double doubleRate = 2;

  /// 锁定/解锁的纵向位移阈值（逻辑像素，对齐参考实现 40.dp）。
  static const double distance = 40;

  /// 是否处于长按流程中。
  bool get active => phase != HoldSpeedPhase.off;

  /// 当前应生效的速率。
  double get rate => phase == HoldSpeedPhase.off ? baseRate : doubleRate;

  /// 按下：用户本来就在 2 倍速时直接视为锁定。
  HoldSpeedState begin(double userRate) {
    final double rate = userRate > 0 ? userRate : 1;
    if (phase == HoldSpeedPhase.locked) {
      // 锁定期间再按住：保留原始 baseRate，解锁后回到它。
      return HoldSpeedState(phase: HoldSpeedPhase.locked, baseRate: baseRate);
    }
    if ((rate - doubleRate).abs() < 0.01) {
      return HoldSpeedState(phase: HoldSpeedPhase.locked, baseRate: rate);
    }
    return HoldSpeedState(phase: HoldSpeedPhase.held, baseRate: rate);
  }

  /// 按住期间累计位移：[dy] 向下为正。
  ///
  /// 按住时下滑锁定、锁定后上滑解锁（参考实现里锁定态判据取反）。
  HoldSpeedState drag(double dy) {
    if (phase == HoldSpeedPhase.off) return this;
    final bool next = phase == HoldSpeedPhase.held
        ? dy >= distance
        : dy <= -distance;
    if (next == armed) return this;
    return HoldSpeedState(phase: phase, baseRate: baseRate, armed: next);
  }

  /// 松手结算。
  HoldSpeedState release() {
    switch (phase) {
      case HoldSpeedPhase.off:
        return this;
      case HoldSpeedPhase.held:
        return armed
            ? HoldSpeedState(phase: HoldSpeedPhase.locked, baseRate: baseRate)
            : HoldSpeedState(baseRate: baseRate);
      case HoldSpeedPhase.locked:
        return armed
            ? HoldSpeedState(baseRate: baseRate)
            : HoldSpeedState(phase: HoldSpeedPhase.locked, baseRate: baseRate);
    }
  }
}
