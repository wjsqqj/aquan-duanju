import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/book_text.dart';
import 'package:aquan_duanju/models/book.dart';

void main() {
  group('htmlToParagraphs', () {
    test('去标签并按块级边界分段', () {
      const html = '<header></header><article>'
          '<h1 class="chapterTitle1" id="head">第1章</h1>'
          '<p>　　陆锋睁开眼。</p>'
          '<p>第二段<br/>换行后的同一段</p>'
          '</article>';
      expect(htmlToParagraphs(html), const [
        '第1章',
        '陆锋睁开眼。',
        '第二段',
        '换行后的同一段',
      ]);
    });

    test('解码实体与数字实体', () {
      const html = '<p>&ldquo;你好&rdquo; &amp; 再见&nbsp;&nbsp;了&#33;</p>';
      expect(htmlToParagraphs(html), const ['“你好” & 再见 了!']);
    });

    test('丢弃 script/style 与注释', () {
      const html = '<style>.a{color:red}</style><!-- hidden -->'
          '<script>var x=1;</script><p>正文</p>';
      expect(htmlToParagraphs(html), const ['正文']);
    });

    test('空行与全角空格不产生空段落', () {
      const html = '<p>　　</p><p>  </p><p>一</p>';
      expect(htmlToParagraphs(html), const ['一']);
    });

    test('空输入返回空列表', () {
      expect(htmlToParagraphs(''), isEmpty);
      expect(htmlToParagraphs('   '), isEmpty);
    });

    test('整段明文（没有标签）也能正常分段', () {
      expect(htmlToParagraphs('第一行\n\n第二行'), const ['第一行', '第二行']);
    });
  });

  group('paragraphsToPlainText', () {
    test('段落之间用空行连接', () {
      expect(paragraphsToPlainText(const ['a', 'b']), 'a\n\nb');
    });
  });

  group('book models', () {
    test('BookDetail 解析并容忍缺字段', () {
      final detail = BookDetail.fromJson(const {
        'id': '7598500561507322904',
        'title': '我都一百岁了，还给双修系统',
        'author': '独白1025',
        'abstract': '简介',
        'cover_url': 'https://cdn/cover.heic',
        'word_count': 2025099,
        'chapter_count': 930,
        'last_chapter_title': '第930章 溜了',
        'category': '玄幻脑洞',
        'score': '8.5',
        'read_count': 195103,
        'finished': true,
      });
      expect(detail.id, '7598500561507322904');
      expect(detail.abstractText, '简介');
      expect(detail.wordCount, 2025099);
      expect(detail.chapterCount, 930);
      expect(detail.finished, isTrue);

      final empty = BookDetail.fromJson(const {'id': '1'});
      expect(empty.title, '');
      expect(empty.chapterCount, 0);
      expect(empty.finished, isFalse);
    });

    test('BookDirectory 解析章节顺序与分卷名', () {
      final dir = BookDirectory.fromJson(const {
        'total': 2,
        'chapters': [
          {'id': 'a', 'title': '第1章', 'volume': '', 'index': 0},
          {'id': 'b', 'title': '第2章', 'volume': '第一卷', 'index': 1},
        ],
      });
      expect(dir.total, 2);
      expect(dir.chapters.length, 2);
      expect(dir.chapters[1].volume, '第一卷');
      expect(dir.chapters[1].index, 1);
      expect(dir.isEmpty, isFalse);
      expect(const BookDirectory().isEmpty, isTrue);
    });
  });
}
