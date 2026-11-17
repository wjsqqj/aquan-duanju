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
