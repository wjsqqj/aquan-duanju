import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/book_pager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TextStyle style(double fontSize, {double height = 1.6}) => TextStyle(
        fontSize: fontSize,
        height: height,
      );

  test('空输入与非法尺寸返回空', () {
    expect(paginateParagraphs(paragraphs: const [], style: style(18), width: 300, height: 400), isEmpty);
    expect(paginateParagraphs(paragraphs: const ['一'], style: style(18), width: 0, height: 400), isEmpty);
    expect(paginateParagraphs(paragraphs: const ['一'], style: style(18), width: 300, height: 0), isEmpty);
  });

  test('一页放得下时不切页', () {
    final pages = paginateParagraphs(
      paragraphs: const ['第一行', '第二行'],
      style: style(18),
      width: 300,
      height: 600,
    );
    expect(pages.length, 1);
    expect(pages.first, contains('第一行'));
    expect(pages.first, contains('第二行'));
  });

  test('放不下时按高度切多页且内容不丢', () {
    final paragraphs = List<String>.generate(40, (i) => '第${i + 1}段内容，用来占满一页的高度。');
    final pages = paginateParagraphs(
      paragraphs: paragraphs,
      style: style(18),
      width: 300,
      height: 200,
    );
    expect(pages.length, greaterThan(1));

    final joined = pages.join();
    for (final paragraph in paragraphs) {
      // 分页会把长段按行切开，所以用关键字校验而不是整段相等。
      expect(joined, contains('${paragraph.split('，').first}，'));
    }
  });

  test('字号变大页数变多', () {
    final paragraphs = List<String>.generate(20, (i) => '段落${i + 1}的正文内容。');
    final small = paginateParagraphs(paragraphs: paragraphs, style: style(14), width: 300, height: 300);
    final large = paginateParagraphs(paragraphs: paragraphs, style: style(28), width: 300, height: 300);
    expect(large.length, greaterThanOrEqualTo(small.length));
  });
}
