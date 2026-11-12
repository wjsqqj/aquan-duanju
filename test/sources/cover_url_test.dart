// 封面 URL 归一单测：相对路径补全与源级 Referer（PRD 11-12 R5）。
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/cover_url.dart';

void main() {
  const api = 'https://api.example.com/api.php/provide/vod/';

  group('absoluteCoverUrl', () {
    test('绝对 http/https 原样返回', () {
      expect(absoluteCoverUrl('https://img.example.com/a.jpg', api),
          'https://img.example.com/a.jpg');
      expect(absoluteCoverUrl('http://img.example.com/a.jpg', api),
          'http://img.example.com/a.jpg');
    });

    test('协议相对 //host/x.jpg → https://host/x.jpg', () {
      expect(absoluteCoverUrl('//img.example.com/x.jpg', api),
          'https://img.example.com/x.jpg');
    });

    test('相对路径以 api 的 origin 补全', () {
      expect(absoluteCoverUrl('/upload/x.jpg', api),
          'https://api.example.com/upload/x.jpg');
    });

    test('空串原样返回', () {
      expect(absoluteCoverUrl('', api), '');
    });

    test('前后空白会清理（XML 的 pic 可能带格式化空白）', () {
      expect(absoluteCoverUrl('  https://img.example.com/a.jpg \n', api),
          'https://img.example.com/a.jpg');
      expect(absoluteCoverUrl(' /upload/x.jpg ', api),
          'https://api.example.com/upload/x.jpg');
    });

    test('api 为空或非法时相对路径原样返回', () {
      expect(absoluteCoverUrl('/upload/x.jpg', ''), '/upload/x.jpg');
      // 无 scheme 的 api 不是可用基准。
      expect(absoluteCoverUrl('/upload/x.jpg', 'relative/api.php'),
          '/upload/x.jpg');
      // 连 Uri 都解析不了的 api。
      expect(absoluteCoverUrl('/upload/x.jpg', '%'), '/upload/x.jpg');
    });
  });

  group('coverRefererOf', () {
    test('返回 scheme://authority/', () {
      expect(coverRefererOf(api), 'https://api.example.com/');
      expect(coverRefererOf('http://127.0.0.1:8080/api.php/provide/vod'),
          'http://127.0.0.1:8080/');
    });

    test('api 无 path 时仍返回 origin', () {
      expect(coverRefererOf('https://api.example.com'),
          'https://api.example.com/');
    });

    test('api 带 userinfo 时不把凭据带进 Referer', () {
      expect(coverRefererOf('https://user:pass@api.example.com/api.php'),
          'https://api.example.com/');
    });

    test('空串 / 非法 api 返回 null', () {
      expect(coverRefererOf(''), isNull);
      expect(coverRefererOf('relative/api.php'), isNull);
      expect(coverRefererOf('http://'), isNull);
      expect(coverRefererOf('%'), isNull);
    });
  });
}
