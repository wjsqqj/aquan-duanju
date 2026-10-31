import 'package:aquan_duanju/core/reader/speech/listen_stats.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 听书统计：墙钟口径、暂停不计数、跨天切分、30 天裁剪。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return SharedPreferences.getInstance();
  }

  test('首次 tick 只建基线，不计数', () async {
    final prefs = await freshPrefs();
    var now = 1000000;
    final stats = ListenStats(prefs, clockMs: () => now);

    stats.tick(); // 基线
    now += 1000;
    stats.tick();

    expect(stats.todayMs, 1000);
  });

  test('间隔超过 5 秒不计（暂停 / 切后台回来）', () async {
    final prefs = await freshPrefs();
    var now = 0;
    final stats = ListenStats(prefs, clockMs: () => now);

    stats.tick();
    now = 6000; // 空档 6 秒
    stats.tick();

    expect(stats.todayMs, 0);
  });

  test('pause 清基线：恢复后第一次 tick 不补空档', () async {
    final prefs = await freshPrefs();
    var now = 0;
    final stats = ListenStats(prefs, clockMs: () => now);

    stats.tick();
    stats.pause();
    now = 1000;
    stats.tick(); // 重新建基线，不计

    expect(stats.todayMs, 0);
  });

  test('负间隔（改系统时间）不计', () async {
    final prefs = await freshPrefs();
    var now = 5000;
    final stats = ListenStats(prefs, clockMs: () => now);

    stats.tick();
    now = 4000;
    stats.tick();

    expect(stats.todayMs, 0);
  });

  test('跨天切分：昨天与今天各记各的', () async {
    final prefs = await freshPrefs();
    final base = DateTime(2026, 10, 30, 23, 59, 59).millisecondsSinceEpoch;
    var now = base;
    final stats = ListenStats(prefs, clockMs: () => now);

    stats.tick(); // 基线（10-30）
    now = base + 1000; // 已跨到 10-31
    stats.tick();

    expect(stats.todayMs, 1000, reason: '这一秒记在今天');
    expect(stats.lastDays(2), <int>[0, 1000], reason: '昨天 0，今天 1000');
  });

  test('flush 落盘后可重新读取', () async {
    final prefs = await freshPrefs();
    var now = 0;
    final first = ListenStats(prefs, clockMs: () => now);
    first.tick();
    now = 2000;
    first.tick();
    await first.flush();

    final second = ListenStats(prefs, clockMs: () => now);
    expect(second.todayMs, 2000);
  });

  test('超过 30 天时裁剪最旧的，且保留最近 30 天', () async {
    final prefs = await freshPrefs();
    final today = DateTime(2026, 10, 31);
    var now = today.millisecondsSinceEpoch;
    final stats = ListenStats(prefs, clockMs: () => now);

    // 连续 35 天，每天 5 × 1s = 5000ms（等于上限，保留）。
    for (var day = 34; day >= 0; day--) {
      now = today.subtract(Duration(days: day)).millisecondsSinceEpoch;
      stats.tick(); // 每天第一条是基线
      for (var i = 0; i < 5; i++) {
        now += 1000;
        stats.tick();
      }
    }
    await stats.flush();

    final raw = prefs.getString(ListenStats.storageKey);
    expect(raw, isNotNull, reason: 'flush 应该写入 prefs');
    expect(raw!.split('"').length, greaterThan(30), reason: '写入的应含多天');

    final reloaded = ListenStats(prefs, clockMs: () => now);
    expect(
      reloaded.totalMs,
      ListenStats.keepDays * 5000,
      reason: '只保留最近 30 天，每天 5 秒',
    );
    expect(reloaded.lastDays(ListenStats.keepDays).length, 30);
  });

  test('坏 JSON 当空，不影响后续计数', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ListenStats.storageKey: '{不是合法 JSON',
    });
    final prefs = await SharedPreferences.getInstance();
    var now = 0;
    final stats = ListenStats(prefs, clockMs: () => now);
    stats.tick();
    now = 1000;
    stats.tick();
    expect(stats.todayMs, 1000);
  });

  test('dayKeyOf 两位补零', () {
    expect(ListenStats.dayKeyOf(DateTime(2026, 1, 5)), '2026-01-05');
    expect(ListenStats.dayKeyOf(DateTime(2026, 12, 31)), '2026-12-31');
  });
}
