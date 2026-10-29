import 'package:aquan_duanju/core/playback_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyPlaybackFailure', () {
    test('空错误按未知处理', () {
      final f = classifyPlaybackFailure(null);
      expect(f.kind, PlaybackFailureKind.unknown);
      expect(f.message, contains('稍后重试'));
    });

    test('域名解析失败是永久错误', () {
      final f = classifyPlaybackFailure(
          "Failed to open https://x: Could not resolve hostname");
      expect(f.kind, PlaybackFailureKind.permanent);
      expect(f.message, contains('域名'));
    });

    test('HTTP 403 是永久错误', () {
      final f = classifyPlaybackFailure('HTTP error 403');
      expect(f.kind, PlaybackFailureKind.permanent);
      expect(f.message, contains('服务器返回错误'));
    });

    test('格式不支持是永久错误', () {
      final f = classifyPlaybackFailure('Failed to recognize file format');
      expect(f.kind, PlaybackFailureKind.permanent);
      final g = classifyPlaybackFailure('format not supported');
      expect(g.kind, PlaybackFailureKind.permanent);
    });

    test('超时是瞬时错误', () {
      final f = classifyPlaybackFailure('connection timed out');
      expect(f.kind, PlaybackFailureKind.transient);
      expect(f.message, contains('连接播放服务器失败'));
    });

    test('连接重置是瞬时错误', () {
      final f = classifyPlaybackFailure('connection reset by peer');
      expect(f.kind, PlaybackFailureKind.transient);
    });

    test('Failed to open + 超时不会被误判为永久错误', () {
      final f = classifyPlaybackFailure(
          'Failed to open https://x/a.m3u8: Connection timed out');
      expect(f.kind, PlaybackFailureKind.transient);
    });

    test('没有音视频数据是瞬时错误', () {
      final f = classifyPlaybackFailure('No audio or video data played');
      expect(f.kind, PlaybackFailureKind.transient);
      expect(f.message, contains('音视频数据'));
    });

    test('原始错误被保留用于诊断', () {
      const raw = 'some raw error';
      final f = classifyPlaybackFailure(raw);
      expect(f.raw, raw);
    });
  });
}
