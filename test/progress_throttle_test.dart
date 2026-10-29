import 'package:aquan_duanju/core/progress_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProgressWriteThrottle', () {
    test('位置差达到间隔才写；0 不写', () {
      final t = ProgressWriteThrottle(interval: const Duration(seconds: 5));
      expect(t.shouldWrite(Duration.zero), isFalse);
      expect(t.shouldWrite(const Duration(seconds: 1)), isTrue);
      expect(t.shouldWrite(const Duration(seconds: 3)), isFalse);
      expect(t.shouldWrite(const Duration(seconds: 6)), isTrue);
      expect(t.shouldWrite(const Duration(seconds: 7)), isFalse);
    });

    test('floor 之前不写，越过一次后解除', () {
      final t = ProgressWriteThrottle(interval: const Duration(seconds: 5));
      t.reset(
        baseline: const Duration(seconds: 100),
        floor: const Duration(seconds: 99),
      );
      expect(t.shouldWrite(const Duration(seconds: 2)), isFalse);
      expect(t.shouldWrite(const Duration(seconds: 98)), isFalse);
      // 越过 floor：解除限制，但距 baseline 不足 5 秒仍不写
      expect(t.shouldWrite(const Duration(seconds: 100)), isFalse);
      expect(t.shouldWrite(const Duration(seconds: 106)), isTrue);
    });

    test('markWritten 同步基线', () {
      final t = ProgressWriteThrottle(interval: const Duration(seconds: 5));
      t.markWritten(const Duration(seconds: 30));
      expect(t.shouldWrite(const Duration(seconds: 32)), isFalse);
      expect(t.shouldWrite(const Duration(seconds: 36)), isTrue);
    });

    test('重新 reset 清空旧基线', () {
      final t = ProgressWriteThrottle();
      t.shouldWrite(const Duration(seconds: 10));
      t.reset(baseline: const Duration(seconds: 20));
      expect(t.shouldWrite(const Duration(seconds: 21)), isFalse);
      expect(t.shouldWrite(const Duration(seconds: 26)), isTrue);
    });
  });
}
