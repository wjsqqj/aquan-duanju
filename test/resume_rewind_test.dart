import 'package:aquan_duanju/core/resume_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resumePositionSeconds（断点回退 3 秒）', () {
    test('正常断点回退 3 秒', () {
      expect(resumePositionSeconds(600), 597);
      expect(resumePositionSeconds(125.9), 122);
    });

    test('小于等于 3 秒时从头开始', () {
      expect(resumePositionSeconds(0), 0);
      expect(resumePositionSeconds(1), 0);
      expect(resumePositionSeconds(3), 0);
      expect(resumePositionSeconds(4), 1);
    });

    test('负数与异常值不产生负秒', () {
      expect(resumePositionSeconds(-10), 0);
      expect(resumePositionSeconds(0.4), 0);
    });

    test('回退秒数就是参考实现的 3', () {
      expect(kResumeRewindSeconds, 3);
    });
  });
}
