/// 静音起播提醒的去重器。
///
/// 口径：**每部影片**播放时只要是静音状态就提醒一次；同一部影片内切集 /
/// 暂停继续 / 拖动不再重复打扰。因此去重键是「影片身份」而不是播放器实例：
/// 优先用标题（换集时地址会变但标题不变），拿不到标题才退回地址。
class MutedPlaybackHintRegistry {
  MutedPlaybackHintRegistry({this.capacity = 64});

  final int capacity;
  final List<String> _order = <String>[];
  final Set<String> _seen = <String>{};

  bool alreadyHinted(String key) => _seen.contains(key);

  /// 登记一次提醒；返回 true 表示「本次应该真的弹出来」。
  bool shouldHint(String key) {
    if (key.isEmpty) return false;
    if (_seen.contains(key)) return false;
    if (_order.length >= capacity) {
      final oldest = _order.removeAt(0);
      _seen.remove(oldest);
    }
    _order.add(key);
    _seen.add(key);
    return true;
  }

  void clear() {
    _order.clear();
    _seen.clear();
  }

  /// 由剧名 / 地址推出「影片身份」。
  static String keyFor({String? title, String? url}) {
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return 't:$t';
    final u = (url ?? '').trim();
    if (u.isNotEmpty) return 'u:$u';
    return '';
  }
}
