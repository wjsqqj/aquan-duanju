import 'package:aquan_duanju/core/reader/speech/chapter_gap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('0 与负数：立即返回且不等待', () async {
    final watch = Stopwatch()..start();
    expect(await awaitChapterGap(0), isTrue);
    expect(await awaitChapterGap(-120), isTrue);
    expect(watch.elapsedMilliseconds, lessThan(80));
  });

  test('正常档位：确实等满 gapMs', () async {
    final watch = Stopwatch()..start();
    expect(await awaitChapterGap(40), isTrue);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(35));
  });

  test('等待结束后按 isCurrent 判决：会话已失效则返回 false', () async {
    var current = true;
    final pending = awaitChapterGap(30, isCurrent: () => current);
    current = false; // 模拟等待期间关闭会话/切章
    expect(await pending, isFalse);
  });

  test('选项表自洽：含默认档且 0 可回滚到硬切', () {
    expect(kChapterGapOptions, contains(kDefaultChapterGapMs));
    expect(kChapterGapOptions.first, 0);
    expect(kChapterGapOptions, orderedEquals(<int>[0, 800, 1500, 3000]));
  });
}
