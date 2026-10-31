/// 听书统计：按天累计「实际听了多久」。
///
/// **口径是墙钟，不是媒体时间**：2 倍速听 30 分钟，用户真正花掉的是 30 分钟 ——
/// 与定时关闭（`sleep_timer.dart`）保持同一口径，两处数字才不会互相打架。
///
/// 设计取舍：
/// - 存 `SharedPreferences` 里一个小 JSON（最多 30 天），不另建文件 store：
///   量级只有几百字节，为它开一套落盘生命周期不划算；
/// - `tick()` 由播放器的位置节拍驱动（1Hz 足够），不自己起 Timer；
/// - **暂停/后台回来后的第一次 tick 必须丢弃**：否则空档会被当成"在听"。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ListenStats {
  ListenStats(this._prefs, {int Function()? clockMs})
    : _clockMs = clockMs ?? _wallClock;

  static const String storageKey = 'listen.stats.daily';

  /// 只保留最近多少天（更久的历史对"今日/本周"没意义，还占 prefs）。
  static const int keepDays = 30;

  /// 单次 tick 计入的上限：超过它就当作"刚才没在听"（暂停 / 切后台 / 息屏）。
  static const int maxTickMs = 5000;

  final SharedPreferences _prefs;
  final int Function() _clockMs;

  final Map<String, int> _daily = <String, int>{};
  bool _loaded = false;
  bool _dirty = false;
  int? _lastTickMs;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (key is String && value is num && value > 0) {
          _daily[key] = value.toInt();
        }
      });
    } catch (_) {
      // 坏数据当空：统计不该拖垮播放。
    }
  }

  /// 播放中由位置节拍驱动（约 1Hz）。**首次调用只建基线**。
  void tick() {
    _ensureLoaded();
    final now = _clockMs();
    final last = _lastTickMs;
    _lastTickMs = now;
    if (last == null) return;
    final delta = now - last;
    // 负值（改系统时间）与超长间隔一律不计。
    if (delta <= 0 || delta > maxTickMs) return;
    final day = dayKeyOf(DateTime.fromMillisecondsSinceEpoch(now));
    _daily[day] = (_daily[day] ?? 0) + delta;
    _dirty = true;
  }

  /// 暂停 / 结束 / 离开页面时调用：清基线，下一次 tick 重新从零算。
  void pause() => _lastTickMs = null;

  /// 落盘（节流：没有变化就直接返回）。
  Future<void> flush() async {
    _ensureLoaded();
    if (!_dirty) return;
    _dirty = false;
    _prune();
    try {
      await _prefs.setString(storageKey, jsonEncode(_daily));
    } catch (_) {
      // 写失败下次再试；统计不是关键路径。
    }
  }

  /// 今天已听毫秒。
  int get todayMs {
    _ensureLoaded();
    return _daily[dayKeyOf(DateTime.fromMillisecondsSinceEpoch(_clockMs()))] ??
        0;
  }

  /// 最近 [count] 天（含今天）的每日毫秒，顺序：旧 → 新。
  List<int> lastDays(int count) {
    _ensureLoaded();
    final today = DateTime.fromMillisecondsSinceEpoch(_clockMs());
    final out = <int>[];
    for (var i = count - 1; i >= 0; i--) {
      final day = today.subtract(Duration(days: i));
      out.add(_daily[dayKeyOf(day)] ?? 0);
    }
    return out;
  }

  /// 最近 7 天合计（书架/设置页的"本周听了多久"）。
  int get last7DaysMs => lastDays(7).fold(0, (sum, value) => sum + value);

  /// 所有留存天的合计。
  int get totalMs {
    _ensureLoaded();
    return _daily.values.fold(0, (sum, value) => sum + value);
  }

  /// `yyyy-MM-dd`。统计的 key 就是这个字符串，跨天自然切分。
  static String dayKeyOf(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  void _prune() {
    if (_daily.length <= keepDays) return;
    final keys = _daily.keys.toList()..sort();
    final drop = keys.length - keepDays;
    for (var i = 0; i < drop; i++) {
      _daily.remove(keys[i]);
    }
  }
}
