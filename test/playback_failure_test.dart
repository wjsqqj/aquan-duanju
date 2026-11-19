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

    test('mpv 解码器初始化失败（未知编码）是永久错误', () {
      final f = classifyPlaybackFailure("Failed to initialize a decoder for codec ''.");
      expect(f.kind, PlaybackFailureKind.permanent);
      expect(f.message, contains('编码'));
    });

    test('media_kit 只透出 END_FILE 原因时按永久错误立即换线', () {
      // URL 403/404 经 media_kit 常只剩 mpv_error_string，没有状态码。
      final f = classifyPlaybackFailure('error: loading failed');
      expect(f.kind, PlaybackFailureKind.permanent);
      final g = classifyPlaybackFailure('nothing to play');
      expect(g.kind, PlaybackFailureKind.permanent);
    });

    test('Error decoding audio 是永久错误（立即换线而非防抖滞留）', () {
      // mpv 每个解码失败的 AAC 帧都报这句（错密钥解 CENC 音频现场，11-20）。
      final f = classifyPlaybackFailure(
          '[ad] Error decoding audio for packet #123');
      expect(f.kind, PlaybackFailureKind.permanent);
      expect(f.message, contains('音频解码失败'));
    });

    test('loading failed 与超时同时出现仍按瞬时处理', () {
      final f = classifyPlaybackFailure(
          'error: loading failed Connection timed out');
      expect(f.kind, PlaybackFailureKind.transient);
    });

    test('原始错误被保留用于诊断', () {
      const raw = 'some raw error';
      final f = classifyPlaybackFailure(raw);
      expect(f.raw, raw);
    });
  });
}
