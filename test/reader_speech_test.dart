import 'package:aquan_duanju/core/reader/reader_paginator.dart';
import 'package:aquan_duanju/core/reader/reader_typography.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 页内听书（朗读高亮）相关的纯函数用例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioTimepoints.paragraphAt（毫秒 → 段落）', () {
    test('有 para 时用精确段落号', () {
      final points = AudioTimepoints(points: [
        const AudioTimepoint(startMs: 0, endMs: 1000, para: 0),
        const AudioTimepoint(startMs: 1000, endMs: 2500, para: 1),
        const AudioTimepoint(startMs: 2500, endMs: 4000, para: 2),
      ]);
      expect(points.paragraphAt(0, paragraphCount: 3), 0);
      expect(points.paragraphAt(1200, paragraphCount: 3), 1);
      expect(points.paragraphAt(3000, paragraphCount: 3), 2);
    });

    test('para 超出本地段落数时被夹紧', () {
      final points = AudioTimepoints(points: [
        const AudioTimepoint(startMs: 0, endMs: 100, para: 9),
      ]);
      expect(points.paragraphAt(10, paragraphCount: 2), 1);
    });

    test('没有 para 时按时间点序号比例插值', () {
      final points = AudioTimepoints(points: [
        const AudioTimepoint(startMs: 0, endMs: 100),
        const AudioTimepoint(startMs: 1000, endMs: 200),
        const AudioTimepoint(startMs: 2000, endMs: 300),
      ]);
      expect(points.paragraphAt(0, paragraphCount: 5), 0);
      expect(points.paragraphAt(1000, paragraphCount: 5), 2);
      expect(points.paragraphAt(2000, paragraphCount: 5), 4);
    });

    test('空时间点或段落数为 0 时返回 0', () {
      expect(
        const AudioTimepoints().paragraphAt(1234, paragraphCount: 5),
        0,
      );
      final points = AudioTimepoints(points: [
        const AudioTimepoint(startMs: 0, endMs: 100, para: 0),
      ]);
      expect(points.paragraphAt(10, paragraphCount: 0), 0);
    });
  });

  group('AudioTimepoints.startMsOfParagraph（段落 → 毫秒）', () {
    test('有 para 时命中精确起点', () {
      final points = AudioTimepoints(points: [
        const AudioTimepoint(startMs: 0, endMs: 900, para: 0),
        const AudioTimepoint(startMs: 900, endMs: 1800, para: 1),
      ]);
      expect(points.startMsOfParagraph(1, paragraphCount: 2), 900);
    });

    test('无 para 时按比例落到时间点上', () {
      final points = AudioTimepoints(points: [
        const AudioTimepoint(startMs: 0, endMs: 100),
        const AudioTimepoint(startMs: 1000, endMs: 200),
      ]);
      expect(points.startMsOfParagraph(0, paragraphCount: 2), 0);
      expect(points.startMsOfParagraph(1, paragraphCount: 2), 1000);
    });
  });

  group('分页器字符位不含段首缩进', () {
    const geometry = ReaderPageGeometry(contentWidth: 320, contentHeight: 520);
    const typography = ReaderTypography(fontSize: 18, lineHeight: 1.8);

    test('第一行 charStart 从段首开始，而不是缩进之后', () {
      final result = paginateReader(
        paragraphs: const ['第一段内容', '第二段内容'],
        typography: typography,
        geometry: geometry,
      );
      final first = result.pages.first.lines.first;
      expect(first.paragraph, 0);
      expect(first.charStart, 0,
          reason: '段首缩进只是渲染效果，不能进章内字符位');
    });

    test('第二段的字符位按段落长度 + 换行符推进', () {
      final result = paginateReader(
        paragraphs: const ['甲乙丙丁', '戊己庚辛'],
        typography: typography,
        geometry: geometry,
      );
      final second = result.pages.first.lines
          .firstWhere((line) => line.paragraph == 1);
      expect(second.charStart, 5,
          reason: '第 2 段从第 1 段长度(4) + 换行(1) 处开始');
    });
  });
}
