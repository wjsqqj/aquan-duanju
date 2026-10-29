import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/discover_channels.dart';
import 'package:aquan_duanju/models/post.dart';

void main() {
  group('CommunityPost', () {
    test('解析块并丢弃空块', () {
      final post = CommunityPost.fromJson(const {
        'id': '7653410992168223256',
        'title': '书荒剧荒必看',
        'author': '小哥的小粉儿',
        'created_at': 1781957977,
        'digg_count': 68,
        'reply_count': 5,
        'favorite_count': 3,
        'tags': ['书荒', '系统流'],
        'blocks': [
          {'type': 'text', 'text': '第一段正文'},
          {'type': 'image', 'url': 'https://cdn/1.heic'},
          {'type': 'image', 'url': ''},
          {'type': 'topic', 'text': '系统流'},
          {'type': 'series', 'series_id': '123', 'title': '某剧'},
          {'type': 'text', 'text': '   '},
        ],
      });
      expect(post.id, '7653410992168223256');
      expect(post.author, '小哥的小粉儿');
      expect(post.diggCount, 68);
      expect(post.tags, const ['书荒', '系统流']);
      // 空图片与空白文本块被丢掉。
      expect(post.blocks.length, 4);
      expect(post.blocks[0].isText, isTrue);
      expect(post.blocks[1].isImage, isTrue);
      expect(post.blocks[2].isTopic, isTrue);
      expect(post.blocks[3].isSeries, isTrue);
      expect(post.blocks[3].seriesId, '123');
    });

    test('textPreview 只取文本块', () {
      final post = CommunityPost.fromJson(const {
        'id': '1',
        'blocks': [
          {'type': 'image', 'url': 'https://cdn/1'},
          {'type': 'text', 'text': '第一段'},
          {'type': 'text', 'text': '第二段'},
        ],
      });
      expect(post.textPreview, '第一段\n第二段');
    });

    test('缺字段时按默认值处理', () {
      final post = CommunityPost.fromJson(const {'id': '2'});
      expect(post.title, '');
      expect(post.blocks, isEmpty);
      expect(post.tags, isEmpty);
      expect(post.textPreview, '');
    });
  });

  group('社区入口', () {
    test('社区不在内容类型条里（它是顶栏独立入口）', () {
      expect(kContentTypes.any((t) => t.name == '社区'), isFalse);
      expect(ContentKind.values.contains(ContentKind.community), isTrue);
    });
  });
}
