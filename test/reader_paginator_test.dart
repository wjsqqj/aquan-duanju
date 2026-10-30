import 'package:aquan_duanju/core/reader/reader_paginator.dart';
import 'package:aquan_duanju/core/reader/reader_typography.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// 去掉所有空白（含全角空格），用于校验「字符一个都没丢」。
String squeeze(String value) =>
    value.replaceAll(RegExp('[ \t\u3000\r\n]'), '');

List<String> longParagraphs(int count, {int charsPerParagraph = 90}) {
  const alphabet = '天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳';
  return [
    for (var i = 0; i < count; i++)
      List.generate(charsPerParagraph, (j) => alphabet[(i + j) % alphabet.length])
          .join(),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const geometry = ReaderPageGeometry(contentWidth: 320, contentHeight: 520);
  const typography = ReaderTypography(fontSize: 18, lineHeight: 1.8);

  test('空输入返回空分页', () {
    expect(
      paginateReader(
        paragraphs: const [],
        typography: typography,
        geometry: geometry,
      ).isEmpty,
      isTrue,
    );
    expect(
      paginateReader(
        paragraphs: const ['一'],
        typography: typography,
        geometry: const ReaderPageGeometry(contentWidth: 0, contentHeight: 0),
      ).isEmpty,
      isTrue,
    );
  });

  test('短文本只有一页且行不为空', () {
    final result = paginateReader(
      paragraphs: const ['第一段。', '第二段。'],
      typography: typography,
      geometry: geometry,
    );
    expect(result.pageCount, 1);
    expect(result.pages.first.lines.length, greaterThanOrEqualTo(2));
    for (final line in result.pages.first.lines) {
      expect(line.text.trim(), isNotEmpty);
    }
  });

  test('长文本多页且字符一个不丢', () {
    final paragraphs = longParagraphs(6);
    final result = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
    );
    expect(result.pageCount, greaterThan(1));

    final rendered = squeeze(
      result.pages.expand((p) => p.lines).map((l) => l.text).join(),
    );
    final source = squeeze(paragraphs.join());
    expect(rendered, source);
  });

  test('每页高度不超过内容区高度', () {
    final result = paginateReader(
      paragraphs: longParagraphs(8),
      typography: typography,
      geometry: geometry,
    );
    for (var i = 0; i < result.pageCount; i++) {
      expect(
        result.pages[i].height,
        lessThanOrEqualTo(geometry.contentHeight + 0.01),
        reason: '第 $i 页高度溢出',
      );
    }
  });

  test('段间距变大页数不减少', () {
    final paragraphs = longParagraphs(5);
    final tight = paginateReader(
      paragraphs: paragraphs,
      typography: typography.copyWith(paragraphSpacing: 0),
      geometry: geometry,
    );
    final loose = paginateReader(
      paragraphs: paragraphs,
      typography: typography.copyWith(paragraphSpacing: 40),
      geometry: geometry,
    );
    expect(loose.pageCount, greaterThanOrEqualTo(tight.pageCount));
  });

  test('章标题占用首页高度', () {
    final paragraphs = longParagraphs(4);
    final withoutTitle = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
    );
    final withTitle = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
      chapterTitle: '第一章 风起于青萍之末',
    );
    expect(
      withTitle.pages.first.lines.length,
      lessThanOrEqualTo(withoutTitle.pages.first.lines.length),
    );
    expect(withTitle.pageCount, greaterThanOrEqualTo(withoutTitle.pageCount));
  });

  test('pageForChar 往返：任意字符落在包含它的页', () {
    final paragraphs = longParagraphs(5);
    final result = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
    );
    final total = result.totalChars;
    for (var offset = 0; offset < total; offset += 17) {
      final index = result.pageForChar(offset);
      final page = result.pages[index];
      expect(
        page.charStart <= offset + 1 && offset <= page.charEnd + 1,
        isTrue,
        reason: 'charOffset=$offset 落在第 $index 页 [${page.charStart}, ${page.charEnd}]',
      );
    }
  });

  test('ratioForChar 单调不减且落在 0..1', () {
    final result = paginateReader(
      paragraphs: longParagraphs(4),
      typography: typography,
      geometry: geometry,
    );
    var last = -1.0;
    for (var offset = 0; offset < result.totalChars; offset += 11) {
      final ratio = result.ratioForChar(offset);
      expect(ratio, inInclusiveRange(0, 1));
      expect(ratio, greaterThanOrEqualTo(last));
      last = ratio;
    }
  });

  test('极窄宽度不崩溃且不丢字', () {
    const narrow = ReaderPageGeometry(contentWidth: 40, contentHeight: 300);
    final paragraphs = longParagraphs(1, charsPerParagraph: 60);
    final result = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: narrow,
    );
    expect(result.pageCount, greaterThan(0));
    expect(
      squeeze(result.pages.expand((p) => p.lines).map((l) => l.text).join()),
      squeeze(paragraphs.join()),
    );
  });

  test('系统字体放大后页数增加', () {
    final paragraphs = longParagraphs(4);
    final normal = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
    );
    final scaled = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: const ReaderPageGeometry(
        contentWidth: 320,
        contentHeight: 520,
        textScaler: TextScaler.linear(1.6),
      ),
    );
    expect(scaled.pageCount, greaterThan(normal.pageCount));
  });

  test('首行缩进只出现在每段第一行', () {
    final result = paginateReader(
      paragraphs: const ['缩进测试文本内容比较长需要折行才能看出缩进是否只在第一行生效啊啊啊'],
      typography: const ReaderTypography(fontSize: 20, lineHeight: 1.8),
      geometry: const ReaderPageGeometry(contentWidth: 160, contentHeight: 600),
    );
    final lines = result.pages.expand((p) => p.lines).toList();
    expect(lines.length, greaterThan(1));
    expect(lines.first.text.startsWith('　　'), isTrue);
    for (final line in lines.skip(1)) {
      expect(line.text.startsWith('　　'), isFalse);
    }
  });

  test('几何与排版相同则结果相同（可缓存）', () {
    final paragraphs = longParagraphs(3);
    final a = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
    );
    final b = paginateReader(
      paragraphs: paragraphs,
      typography: typography,
      geometry: geometry,
    );
    expect(a.pageCount, b.pageCount);
    for (var i = 0; i < a.pageCount; i++) {
      expect(a.pages[i].lines.length, b.pages[i].lines.length);
      expect(a.pages[i].charStart, b.pages[i].charStart);
    }
  });
}
