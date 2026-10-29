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

  test('翻页动画：当前页始终居中不变暗', () {
    for (final animation in PageAnimation.values) {
      final frame = pageFrameFor(0, animation);
      expect(frame.dxRatio, closeTo(0, 1e-9));
      expect(frame.dim, closeTo(0, 1e-9));
      expect(frame.scale, closeTo(1, 1e-9));
    }
  });

  test('覆盖动画：新页压上来，旧页变暗不移动', () {
    final incoming = pageFrameFor(1, PageAnimation.cover);
    expect(incoming.dxRatio, closeTo(1, 1e-9));
    expect(incoming.dim, closeTo(0, 1e-9));

    final outgoing = pageFrameFor(-1, PageAnimation.cover);
    expect(outgoing.dxRatio, closeTo(0, 1e-9));
    expect(outgoing.dim, greaterThan(0));
    expect(outgoing.scale, lessThan(1));
  });

  test('卷曲动画：新页逐渐揭开，旧页变暗', () {
    final mid = pageFrameFor(0.5, PageAnimation.curl);
    expect(mid.curl, closeTo(0.5, 1e-9));
    expect(mid.dim, closeTo(0, 1e-9));

    final gone = pageFrameFor(-1, PageAnimation.curl);
    expect(gone.curl, closeTo(0, 1e-9));
    expect(gone.dim, greaterThan(0));
  });

  test('字号变大页数变多', () {
    final paragraphs = List<String>.generate(20, (i) => '段落${i + 1}的正文内容。');
    final small = paginateParagraphs(paragraphs: paragraphs, style: style(14), width: 300, height: 300);
    final large = paginateParagraphs(paragraphs: paragraphs, style: style(28), width: 300, height: 300);
    expect(large.length, greaterThanOrEqualTo(small.length));
  });
}
