import 'package:aquan_duanju/core/playback_fallback.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

VideoStream stream(
  String definition, {
  String quality = '',
  String url = '',
  String backupUrl = '',
  int height = 0,
  int bitrate = 0,
}) =>
    VideoStream(
      definition: definition,
      quality: quality,
      url: url,
      backupUrl: backupUrl,
      height: height,
      bitrate: bitrate,
    );

void main() {
  group('planPlaybackCandidates', () {
    test('当前流备用地址排第一，随后同清晰度、再按档位距离', () {
      final current = stream('720p', url: 'c', backupUrl: 'cb', height: 720);
      final streams = [
        current,
        stream('720p', url: 'same', height: 720),
        stream('1080p', url: 'high', height: 1080),
        stream('480p', url: 'low', height: 480),
        stream('', url: '', height: 0), // 空地址不参与
      ];
      final candidates = planPlaybackCandidates(
        streams: streams,
        current: current,
        tried: const {},
      );
      expect(candidates.map((c) => c.url).toList(),
          ['cb', 'same', 'low', 'high']);
      expect(candidates.first.backup, isTrue);
      expect(candidates.first.label, '720p · 备用');
    });

    test('跳过已尝试地址与当前地址，按 URL 去重', () {
      final current = stream('720p', url: 'c', backupUrl: 'cb');
      final streams = [
        current,
        stream('720p', url: 'cb'), // 与其他流的备用地址重复
        stream('480p', url: 'low'),
      ];
      final candidates = planPlaybackCandidates(
        streams: streams,
        current: current,
        tried: {'low'},
      );
      expect(candidates.map((c) => c.url), ['cb']);
    });

    test('maxCandidates 截断', () {
      final current = stream('720p', url: 'c');
      final streams = [
        current,
        for (var i = 1; i <= 6; i++) stream('${i}00p', url: 'u$i', height: i * 100),
      ];
      final candidates = planPlaybackCandidates(
        streams: streams,
        current: current,
        tried: const {},
        maxCandidates: 3,
      );
      expect(candidates.length, 3);
    });

    test('未知清晰度排到最后且不崩溃', () {
      final current = stream('720p', url: 'c', height: 720);
      final streams = [
        current,
        stream('', url: 'unknown'), // rank 0 -> 距离 1000
        stream('480p', url: 'low', height: 480),
      ];
      final candidates = planPlaybackCandidates(
        streams: streams,
        current: current,
        tried: const {},
      );
      expect(candidates.map((c) => c.url), ['low', 'unknown']);
    });

    test('无备用时返回空', () {
      final current = stream('720p', url: 'c');
      final candidates = planPlaybackCandidates(
        streams: [current],
        current: current,
        tried: const {},
      );
      expect(candidates, isEmpty);
    });
  });

  group('streamLabel / streamRank', () {
    test('标签与权重', () {
      expect(streamLabel(stream('', quality: '')), '默认');
      expect(streamRank(stream('', height: 1080)), 1080);
      expect(streamRank(stream('720p')), 720);
      expect(streamRank(stream('')), 0);
    });
  });
}
