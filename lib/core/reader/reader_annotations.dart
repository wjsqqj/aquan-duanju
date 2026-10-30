/// 阅读批注模型：书签与划线。
///
/// 两者都以**章内字符偏移**为锚点（不是页号、不是像素），因此改字号、改行距、
/// 换主题之后位置依然准确；换源导致正文变化时由调用方决定是否丢弃。
library;

/// 划线颜色。
enum MarkingColor {
  yellow(0xFFFFE082, '黄'),
  green(0xFFA5D6A7, '绿'),
  blue(0xFF90CAF9, '蓝'),
  pink(0xFFF48FB1, '粉'),
  purple(0xFFB39DDB, '紫');

  const MarkingColor(this.argb, this.label);

  final int argb;
  final String label;

  static MarkingColor fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return MarkingColor.yellow;
  }
}

/// 书签。
class ReaderBookmark {
  const ReaderBookmark({
    required this.id,
    required this.bookId,
    required this.chapterId,
    required this.chapterIndex,
    required this.charOffset,
    this.chapterTitle = '',
    this.excerpt = '',
    this.note = '',
    required this.createdAt,
  });

  factory ReaderBookmark.fromJson(Map<String, dynamic> json) => ReaderBookmark(
        id: json['id'] as String? ?? '',
        bookId: json['book_id'] as String? ?? '',
        chapterId: json['chapter_id'] as String? ?? '',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        charOffset: (json['char_offset'] as num?)?.toInt() ?? 0,
        chapterTitle: json['chapter_title'] as String? ?? '',
        excerpt: json['excerpt'] as String? ?? '',
        note: json['note'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  final String id;
  final String bookId;
  final String chapterId;
  final int chapterIndex;

  /// 章内字符偏移（与分页无关）。
  final int charOffset;

  final String chapterTitle;

  /// 摘录：建立书签时所在页的开头若干字。
  final String excerpt;
  final String note;
  final DateTime createdAt;

  ReaderBookmark copyWith({String? note, String? excerpt}) => ReaderBookmark(
        id: id,
        bookId: bookId,
        chapterId: chapterId,
        chapterIndex: chapterIndex,
        charOffset: charOffset,
        chapterTitle: chapterTitle,
        excerpt: excerpt ?? this.excerpt,
        note: note ?? this.note,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'book_id': bookId,
        'chapter_id': chapterId,
        'chapter_index': chapterIndex,
        'char_offset': charOffset,
        'chapter_title': chapterTitle,
        'excerpt': excerpt,
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };
}

/// 划线 / 批注。
class ReaderMarking {
  const ReaderMarking({
    required this.id,
    required this.bookId,
    required this.chapterId,
    required this.chapterIndex,
    required this.charStart,
    required this.charEnd,
    required this.text,
    this.chapterTitle = '',
    this.note = '',
    this.color = MarkingColor.yellow,
    required this.createdAt,
  });

  factory ReaderMarking.fromJson(Map<String, dynamic> json) => ReaderMarking(
        id: json['id'] as String? ?? '',
        bookId: json['book_id'] as String? ?? '',
        chapterId: json['chapter_id'] as String? ?? '',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        charStart: (json['char_start'] as num?)?.toInt() ?? 0,
        charEnd: (json['char_end'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
        chapterTitle: json['chapter_title'] as String? ?? '',
        note: json['note'] as String? ?? '',
        color: MarkingColor.fromName(json['color']),
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  final String id;
  final String bookId;
  final String chapterId;
  final int chapterIndex;

  /// 区间 `[charStart, charEnd)`。
  final int charStart;
  final int charEnd;

  /// 被划线的原文（用于换排版后做文本校验）。
  final String text;
  final String chapterTitle;
  final String note;
  final MarkingColor color;
  final DateTime createdAt;

  int get length => charEnd - charStart;

  bool overlaps(int start, int end) => charStart < end && start < charEnd;

  ReaderMarking copyWith({String? note, MarkingColor? color}) => ReaderMarking(
        id: id,
        bookId: bookId,
        chapterId: chapterId,
        chapterIndex: chapterIndex,
        charStart: charStart,
        charEnd: charEnd,
        text: text,
        chapterTitle: chapterTitle,
        note: note ?? this.note,
        color: color ?? this.color,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'book_id': bookId,
        'chapter_id': chapterId,
        'chapter_index': chapterIndex,
        'char_start': charStart,
        'char_end': charEnd,
        'text': text,
        'chapter_title': chapterTitle,
        'note': note,
        'color': color.name,
        'created_at': createdAt.toIso8601String(),
      };
}
