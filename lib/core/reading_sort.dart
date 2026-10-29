import '../store/stores.dart';

/// 书架排序方式。
enum ReadingSort {
  /// 最近读过在前。
  recent,

  /// 按书名。
  title,

  /// 读得最多的在前。
  progress,
}

/// 按 [sort] 排阅读记录；返回新列表，不改入参。
///
/// `title` 走 Unicode 码位序（不是拼音序）；要拼音序得另外接映射表。
List<ReadingEntry> sortReadingEntries(
    List<ReadingEntry> entries, ReadingSort sort) {
  final list = [...entries];
  switch (sort) {
    case ReadingSort.recent:
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    case ReadingSort.title:
      list.sort((a, b) => a.title.compareTo(b.title));
    case ReadingSort.progress:
      list.sort((a, b) {
        final byPercent = b.percent.compareTo(a.percent);
        if (byPercent != 0) return byPercent;
        return b.updatedAt.compareTo(a.updatedAt);
      });
  }
  return list;
}

/// 排序方式的中文名。
String readingSortLabel(ReadingSort sort) => switch (sort) {
      ReadingSort.recent => '最近读',
      ReadingSort.title => '书名',
      ReadingSort.progress => '进度',
    };
