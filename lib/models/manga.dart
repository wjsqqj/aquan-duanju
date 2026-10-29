/// 漫画：一话的图片清单（与 core `chapterPages` 输出对应）。
library;

class MangaPage {
  const MangaPage({required this.url, this.width = 0, this.height = 0});

  final String url;
  final int width;
  final int height;

  /// 宽高比；缺尺寸时按常见条漫比例兜底。
  double get aspectRatio =>
      width > 0 && height > 0 ? width / height : 1000 / 1500;

  factory MangaPage.fromJson(Map<String, dynamic> json) => MangaPage(
        url: json['url'] as String? ?? '',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
      );
}

class MangaChapterPages {
  const MangaChapterPages({
    this.itemId = '',
    this.key = '',
    this.pages = const [],
  });

  final String itemId;

  /// 整话共用的 AES-256-GCM 密钥（hex）；为空表示图片未加密。
  final String key;
  final List<MangaPage> pages;

  bool get isEmpty => pages.isEmpty;

  factory MangaChapterPages.fromJson(Map<String, dynamic> json) =>
      MangaChapterPages(
        itemId: json['item_id'] as String? ?? '',
        key: json['key'] as String? ?? '',
        pages: (json['pages'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MangaPage.fromJson)
            .where((p) => p.url.isNotEmpty)
            .toList(),
      );
}
