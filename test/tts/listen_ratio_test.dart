import 'package:aquan_duanju/core/reader/speech/listen_format.dart';
import 'package:aquan_duanju/screens/book_audio_screen.dart';
import 'package:aquan_duanju/widgets/reader/reader_audio_bar.dart';
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

  group('ReaderAudioBar.subtitleOf', () {
    test('无剩余时间时只显示章序号', () {
      expect(ReaderAudioBar.subtitleOf(12, 3, null), '第 3 / 12 章');
      expect(ReaderAudioBar.subtitleOf(0, 0, null), '');
    });

    test('有剩余时间时拼上「剩 mm:ss」', () {
      expect(
        ReaderAudioBar.subtitleOf(12, 3, const Duration(seconds: 754)),
        '第 3 / 12 章 · 剩 12:34',
      );
      // 章序号未知也能单独显示剩余时间。
      expect(
        ReaderAudioBar.subtitleOf(0, 0, const Duration(seconds: 5)),
        '剩 00:05',
      );
    });
  });
}
