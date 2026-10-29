import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_health.dart';

void main() {
  test('EMA 延迟平滑：首记即值，后续 (avg*3+x)/4', () {
    final r = SourceHealthRecord();
    r.recordSuccess(1000);
    expect(r.avgLatencyMs, 1000);
    r.recordSuccess(500);
    expect(r.avgLatencyMs, closeTo(875, 0.01));
    r.recordSuccess(0);
    expect(r.avgLatencyMs, closeTo(656.25, 0.01));
    expect(r.successes, 3);
  });

  test('健康分公式：成功×1000 − 失败×500 − 延迟/10', () {
    final r = SourceHealthRecord()
      ..recordSuccess(1000)
      ..recordSuccess(500);
    // successes=2, avg=875 → 2000 − 87 = 1913
    expect(r.score, 2000 - 500 * 0 - 875 ~/ 10);

    r.recordFailure('超时');
    // failures=1 → 2000 − 500 − 87 = 1413
    expect(r.score, 2000 - 500 - 875 ~/ 10);
  });

  test('冷却：搜索 2min / 播放 30min，成功即清除', () {
    final base = DateTime(2026, 10, 30, 12);
    final r = SourceHealthRecord();
    r.recordFailure('搜索失败', now: base);
    expect(r.isCoolingDown(base.add(const Duration(seconds: 1))), isTrue);
    expect(r.isCoolingDown(base.add(const Duration(minutes: 3))), isFalse);

    r.recordFailure('播放失败', playFailure: true, now: base);
    expect(r.isCoolingDown(base.add(const Duration(minutes: 10))), isTrue);
    expect(r.isCoolingDown(base.add(const Duration(minutes: 31))), isFalse);

    r.recordSuccess(100, now: base);
    expect(r.isCoolingDown(base), isFalse);
    expect(r.lastError, isEmpty);
  });

  test('JSON 往返', () {
    final r = SourceHealthRecord()
      ..recordSuccess(640)
      ..recordFailure('HTTP 500');
    final back = SourceHealthRecord.fromJson(r.toJson());
    expect(back.successes, r.successes);
    expect(back.failures, r.failures);
    expect(back.avgLatencyMs, r.avgLatencyMs);
    expect(back.cooldownUntil, r.cooldownUntil);
    expect(back.score, r.score);
  });
}
