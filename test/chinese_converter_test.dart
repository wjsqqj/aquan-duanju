import 'package:aquan_duanju/core/reader/chinese_converter.dart';
import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('关闭时原样返回', () {
    expect(ChineseConverter.convert('繁體字', ChineseConvert.off), '繁體字');
    expect(ChineseConverter.convert('', ChineseConvert.t2s), '');
  });

  test('繁转简常见字', () {
    final out = ChineseConverter.convert('這個問題很難說清楚', ChineseConvert.t2s);
    expect(out, '这个问题很难说清楚');
  });

  test('简转繁常见字', () {
    final out = ChineseConverter.convert('这个问题的风', ChineseConvert.s2t);
    expect(out.contains('這'), isTrue);
    expect(out.contains('風'), isTrue);
  });

  test('词表优先：乾隆不会被单字表拆坏', () {
    final out = ChineseConverter.convert('乾隆皇帝', ChineseConvert.t2s);
    expect(out, contains('乾隆'));
    expect(out.startsWith('乾'), isTrue);
  });

  test('中英混排只转中文', () {
    final out = ChineseConverter.convert('Hello 世界 ABC', ChineseConvert.t2s);
    expect(out, 'Hello 世界 ABC');
  });

  test('转换幂等：t2s 结果再 t2s 不变', () {
    const source = '閱讀是一種享受，繁體字也能看懂。';
    final once = ChineseConverter.convert(source, ChineseConvert.t2s);
    final twice = ChineseConverter.convert(once, ChineseConvert.t2s);
    expect(twice, once);
  });

  test('长文本长度稳定（单字映射不改变字符数）', () {
    final source = List.filled(200, '這個問題').join();
    final out = ChineseConverter.convert(source, ChineseConvert.t2s);
    expect(out.length, source.length);
    expect(out.contains('這'), isFalse);
  });

  test('hasWork 能判断是否需要转换', () {
    expect(ChineseConverter.hasWork('这个', ChineseConvert.t2s), isFalse);
    expect(ChineseConverter.hasWork('這個', ChineseConvert.t2s), isTrue);
    expect(ChineseConverter.hasWork('這個', ChineseConvert.off), isFalse);
  });

  test('标点与数字不受影响', () {
    const source = '2026 年，第 3 章「測試」——完成！';
    final out = ChineseConverter.convert(source, ChineseConvert.t2s);
    expect(out.contains('2026'), isTrue);
    expect(out.contains('，'), isTrue);
    expect(out.contains('——'), isTrue);
    expect(out.contains('！'), isTrue);
    expect(out.contains('测试'), isTrue);
  });
}
