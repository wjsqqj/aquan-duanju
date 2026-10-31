import 'package:aquan_duanju/screens/book_audio_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 听书页 → 阅读页的定位比例：时间比例是唯一诚实可行的近似。
void main() {
  test('总时长未知：返回 0，不编一个比例', () {
    expect(listenRatioOf(const Duration(seconds: 30), 0), 0);
    expect(listenRatioOf(const Duration(seconds: 30), -5), 0);
  });

  test('正常比例与边界夹取', () {
    expect(listenRatioOf(const Duration(seconds: 30), 120000), closeTo(0.25, 1e-9));
    expect(listenRatioOf(Duration.zero, 120000), 0);
    // 位置越过总时长（Track 时长比实际短）时夹到 1，不能溢出到页外。
    expect(listenRatioOf(const Duration(seconds: 200), 120000), 1);
    expect(listenRatioOf(const Duration(seconds: 120), 120000), 1);
  });

  group('formatListenTime', () {
    test('mm:ss 两位补零', () {
      expect(formatListenTime(Duration.zero), '00:00');
      expect(formatListenTime(const Duration(seconds: 5)), '00:05');
      expect(formatListenTime(const Duration(seconds: 59)), '00:59');
      expect(formatListenTime(const Duration(minutes: 1, seconds: 5)), '01:05');
    });

    test('超过一小时不截断分钟（音轨可能很长）', () {
      expect(
        formatListenTime(const Duration(hours: 1, minutes: 2, seconds: 5)),
        '62:05',
      );
    });

    test('负数位置当 0：不出现 -1:-5', () {
      expect(formatListenTime(const Duration(seconds: -3)), '00:00');
    });
  });
}
