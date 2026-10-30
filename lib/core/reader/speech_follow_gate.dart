/// 朗读「自动跟随」的闸门：谁碰了页面、什么时候该跟、什么时候该停手。
///
/// 从 `reader_screen` 抽出来只有两个理由：① 这套「锁 → 挂起 → 药丸」的状态机必须
/// 能被逐条钉住（整页 widget 测试要 mock 的插件比行为本身还多）；② 它是纯时间判断，
/// 不该和 `BuildContext` 纠缠。页面只做两件事：把用户动作报进来、执行它给出的跳页决定。
///
/// **这里从不暂停朗读，也从不改任何进度**（design.md §5：解跟不抢回、不中断）。
library;

import 'dart:async';

/// 手动操作后的解跟锁：沿用改造前 `reader_screen._lockFollow()` 的 1500ms 手感。
const Duration kSpeechFollowLock = Duration(milliseconds: 1500);

/// 跟随闸门：三段行为 —— 锁内不跟、锁满转挂起、药丸恢复。
class SpeechFollowGate {
  SpeechFollowGate({
    this.lockWindow = kSpeechFollowLock,
    this.repaint = _noop,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 锁窗口长度。
  final Duration lockWindow;

  /// 挂起状态**会在没有任何朗读事件的时刻到期**：页面需要这个回调把药丸画出来。
  final void Function() repaint;

  final DateTime Function() _clock;

  /// 锁的到期时刻；`null` = 没有锁，正常跟随。
  DateTime? _lockUntil;

  /// 锁期间用户是否真的翻过页（只是开了个菜单不该弹药丸）。
  bool _turnedDuringLock = false;

  bool _suspended = false;
  Timer? _settle;

  /// 已经「不跟了，等用户点药丸」。
  bool get suspended => _suspended;

  /// 用户手动翻了页（滑动 / 九宫格翻页 / 书签跳页）：上锁并记下「期间翻过页」。
  void noteManualTurn() {
    _lockUntil = _clock().add(lockWindow);
    _turnedDuringLock = true;
    _armSettle();
  }

  /// 用户做了别的页面动作（开菜单、点页码区、换章）：短暂上锁，但**不会**转挂起。
  void noteUserAction() {
    _lockUntil = _clock().add(lockWindow);
    _armSettle();
  }

  /// 重新开始朗读 / 点「继续跟随」：回到跟随状态，锁也一并清掉。
  void resume() {
    _settle?.cancel();
    _settle = null;
    _lockUntil = null;
    _turnedDuringLock = false;
    _suspended = false;
  }

  /// 现在能不能跟随。
  bool shouldFollow() {
    _settleNow();
    return !_suspended && _lockUntil == null;
  }

  /// 跳页决定（**句优先**）：只有底纹区间的**起点**落到别的页时才跳。
  ///
  /// 底纹区间取「当前句」，音轨路径没有句表时退化为「当前段落」——两者都**不含词**，
  /// 所以词级推进时 `baseCharStart` 不变，这里必然返回 `null`：一次 `jumpTo` 都不会
  /// 发生（design.md §5「词级高亮不得触发 jumpTo」）。
  int? targetPage({
    required bool enabled,
    required int? baseCharStart,
    required int currentPage,
    required int Function(int charStart) pageForChar,
  }) {
    if (!enabled) return null;
    final start = baseCharStart;
    if (start == null) return null;
    if (!shouldFollow()) return null;
    final page = pageForChar(start);
    return page == currentPage ? null : page;
  }

  void dispose() {
    _settle?.cancel();
    _settle = null;
  }

  void _armSettle() {
    _settle?.cancel();
    _settle = null;
    final until = _lockUntil;
    if (until == null) return;
    final remaining = until.difference(_clock());
    _settle = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      _settleNow,
    );
  }

  /// 锁到期结算：期间确实手动翻过页才转挂起。
  void _settleNow() {
    final until = _lockUntil;
    if (until == null || _clock().isBefore(until)) return;
    _lockUntil = null;
    if (!_turnedDuringLock) return;
    _turnedDuringLock = false;
    if (_suspended) return;
    _suspended = true;
    repaint();
  }

  static void _noop() {}
}
