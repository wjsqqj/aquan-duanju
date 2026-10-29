import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/reading_sort.dart';
import 'package:aquan_duanju/store/stores.dart';

ReadingEntry entry(String title, int index, int chapters, int at) => ReadingEntry(
      bookId: title,
      title: title,
      chapterIndex: index,
      chapters: chapters,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
    );

void main() {
  final entries = [
    entry('乙书', 1, 10, 3000),
    entry('甲书', 7, 10, 5000),
    entry('丙书', 3, 10, 1000),
  ];

  test('最近读：最新在前', () {
    final sorted = sortReadingEntries(entries, ReadingSort.recent);
    expect(sorted.map((e) => e.title).toList(), ['甲书', '乙书', '丙书']);
  });

  test('书名：按标题排序（Unicode 码位序）', () {
    final sorted = sortReadingEntries(entries, ReadingSort.title);
    // Dart 的字符串比较是码位序：丙(19993) < 乙(20057) < 甲(30002)。
    expect(sorted.map((e) => e.title).toList(), ['丙书', '乙书', '甲书']);
  });

  test('进度：读得最多的在前', () {
    final sorted = sortReadingEntries(entries, ReadingSort.progress);
    expect(sorted.map((e) => e.title).toList(), ['甲书', '丙书', '乙书']);
  });

  test('进度相同时按最近读兜底', () {
    final same = [
      entry('A', 1, 10, 1000),
      entry('B', 1, 10, 9000),
    ];
    final sorted = sortReadingEntries(same, ReadingSort.progress);
    expect(sorted.map((e) => e.title).toList(), ['B', 'A']);
  });

  test('不改动入参', () {
    final original = [...entries];
    sortReadingEntries(entries, ReadingSort.title);
    expect(entries.map((e) => e.title).toList(),
        original.map((e) => e.title).toList());
  });

  test('排序名有中文', () {
    expect(readingSortLabel(ReadingSort.recent), '最近读');
    expect(readingSortLabel(ReadingSort.title), '书名');
    expect(readingSortLabel(ReadingSort.progress), '进度');
  });
}
