import 'package:aquan_duanju/core/playback_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('maskSensitiveUrl', () {
    test('敏感 query 值打码', () {
      final masked = maskSensitiveUrl(
          'https://cdn.example.com/a.m3u8?token=abc123&id=42&sign=xyz');
      expect(masked, contains('token=***'));
      expect(masked, contains('sign=***'));
      expect(masked, contains('id=42'));
    });

    test('userinfo 打码', () {
      expect(
        maskSensitiveUrl('https://user:pass@cdn.example.com/a.mp4'),
        'https://***@cdn.example.com/a.mp4',
      );
    });

    test('decryption_key 打码', () {
      final masked = maskSensitiveUrl(
          'https://x/a.mp4?decryption_key=0123456789abcdef0123456789abcdef');
      expect(masked, isNot(contains('0123456789abcdef')));
      expect(masked, contains('decryption_key=***'));
    });
  });

  group('maskSensitiveHeaders', () {
    test('只抹敏感头，保留 Referer / UA', () {
      final masked = maskSensitiveHeaders({
        'Authorization': 'Bearer secret',
        'Cookie': 'a=b',
        'Referer': 'https://site/',
        'User-Agent': 'ua',
      });
      expect(masked['Authorization'], '***');
      expect(masked['Cookie'], '***');
      expect(masked['Referer'], 'https://site/');
      expect(masked['User-Agent'], 'ua');
    });
  });

  group('maskLogLines', () {
    test('日志里的完整地址与密钥都被替换', () {
      const url = 'https://cdn/a.m3u8?token=secret';
      final masked = maskLogLines(
        [
          'Opening $url',
          'demuxer-lavf-o: decryption_key=0123456789abcdef0123456789abcdef',
          'header Authorization: Bearer abc12345',
        ],
        rawUrl: url,
        maskedUrl: maskSensitiveUrl(url),
        rawHeaders: const {'Authorization': 'Bearer abc12345'},
      );
      expect(masked[0], isNot(contains('token=secret')));
      expect(masked[1], isNot(contains('0123456789abcdef')));
      expect(masked[2], isNot(contains('abc12345')));
    });
  });

  group('RecentLogBuffer', () {
    test('固定容量丢最旧，忽略空行', () {
      final buffer = RecentLogBuffer(capacity: 3);
      buffer
        ..add('a')
        ..add('  ')
        ..add('b')
        ..add('c')
        ..add('d');
      expect(buffer.entries, ['b', 'c', 'd']);
      buffer.clear();
      expect(buffer.isEmpty, isTrue);
    });
  });

  group('buildPlaybackDiagnosticText', () {
    test('包含影片/分集/脱敏地址与日志', () {
      const raw =
          'failed https://cdn/a.mp4?token=secret&decryption_key=0123456789abcdef0123456789abcdef';
      final text = buildPlaybackDiagnosticText(
        rawError: raw,
        engineLogs: [raw],
        url: 'https://cdn/a.mp4?token=secret',
        title: '测试剧',
        episodeNumber: 5,
        episodeTitle: '大结局',
        quality: '720p',
        now: DateTime(2026, 10, 29, 12),
      );
      expect(text, contains('测试剧'));
      expect(text, contains('第5集'));
      expect(text, contains('720p'));
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('0123456789abcdef0123456789abcdef')));
      expect(text, contains('引擎日志'));
    });
  });
}
