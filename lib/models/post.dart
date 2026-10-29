/// 社区帖子（与 core `postDetail` 输出对应）。
library;

/// 帖子正文的一块：按顺序渲染。
class PostBlock {
  const PostBlock({
    required this.type,
    this.text = '',
    this.url = '',
    this.seriesId = '',
    this.title = '',
  });

  /// text / image / topic / series。
  final String type;
  final String text;
  final String url;
  final String seriesId;
  final String title;

  bool get isText => type == 'text';
  bool get isImage => type == 'image';
  bool get isTopic => type == 'topic';
  bool get isSeries => type == 'series';

  factory PostBlock.fromJson(Map<String, dynamic> json) => PostBlock(
        type: json['type'] as String? ?? '',
        text: json['text'] as String? ?? '',
        url: json['url'] as String? ?? '',
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
      );
}

class CommunityPost {
  const CommunityPost({
    required this.id,
    this.title = '',
    this.author = '',
    this.createdAt = 0,
    this.diggCount = 0,
    this.replyCount = 0,
    this.favoriteCount = 0,
    this.tags = const [],
    this.blocks = const [],
  });

  final String id;
  final String title;
  final String author;

  /// Unix 秒。
  final int createdAt;
  final int diggCount;
  final int replyCount;
  final int favoriteCount;
  final List<String> tags;
  final List<PostBlock> blocks;

  /// 纯文本块，列表页与复制用。
  String get textPreview => blocks
      .where((b) => b.isText && b.text.trim().isNotEmpty)
      .map((b) => b.text.trim())
      .take(3)
      .join('\n');

  factory CommunityPost.fromJson(Map<String, dynamic> json) => CommunityPost(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        diggCount: (json['digg_count'] as num?)?.toInt() ?? 0,
        replyCount: (json['reply_count'] as num?)?.toInt() ?? 0,
        favoriteCount: (json['favorite_count'] as num?)?.toInt() ?? 0,
        tags: (json['tags'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        blocks: (json['blocks'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PostBlock.fromJson)
            // 空块不渲染；剧集卡片靠 series_id 存在。
            .where((b) =>
                b.url.isNotEmpty ||
                b.text.trim().isNotEmpty ||
                b.seriesId.isNotEmpty)
            .toList(),
      );
}
