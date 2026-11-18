import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 搜索结果类型分流的接线证据。
void main() {
  test('搜索页按 kind 进入帖子 / 书籍 / 人物 / 剧集详情', () {
    final String source =
        File('lib/screens/search_screen.dart').readAsStringSync();
    final int start = source.indexOf('void _openResult(');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    expect(body, contains("case 'post':"));
    expect(body, contains('PostDetailScreen(postId: item.id'));
    expect(body, contains("case 'book':"));
    expect(body, contains('BookDetailScreen('));
    expect(body, contains("case 'user':"));
    expect(body, contains('PersonScreen(userId: item.id'));
    expect(body, contains('openDetail(context, item.id'));
    expect(source, contains('onTap: _openResult'));
  });

  test('同名单剧过滤排除非剧类型', () {
    final String source =
        File('lib/screens/detail_screen.dart').readAsStringSync();
    final int start = source.indexOf('Future<void> _loadSameName(');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    final String body = source.substring(start, end);

    expect(body, contains('s.isSeriesLike'));
    expect(body, contains('s.episodeCount > 0'));
  });
}
