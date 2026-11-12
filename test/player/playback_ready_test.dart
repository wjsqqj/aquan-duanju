import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player/playback_ready.dart';

void main() {
  group('waitForPlaybackReady', () {
    late StreamController<Duration> duration;
    late StreamController<bool> playing;

    setUp(() {
      duration = StreamController<Duration>();
      playing = StreamController<bool>();
    });

    tearDown(() async {
      await duration.close();
      await playing.close();
    });

    test('duration 推到非零 → 返回 true', () async {
      final future = waitForPlaybackReady(
        duration: duration.stream,
        playing: playing.stream,
      );

      duration.add(const Duration(seconds: 30));

      expect(await future, isTrue);
    });

    test('playing 推 true → 返回 true', () async {
      final future = waitForPlaybackReady(
        duration: duration.stream,
        playing: playing.stream,
      );

      playing.add(true);

      expect(await future, isTrue);
    });

    test('无就绪事件 → 超时返回 false', () async {
      final ready = await waitForPlaybackReady(
        duration: duration.stream,
        playing: playing.stream,
        timeout: const Duration(milliseconds: 50),
      );

      expect(ready, isFalse);
    });

    test('duration 推 Duration.zero 不算就绪 → 超时返回 false', () async {
      final future = waitForPlaybackReady(
        duration: duration.stream,
        playing: playing.stream,
        timeout: const Duration(milliseconds: 30),
      );

      duration.add(Duration.zero);

      expect(await future, isFalse);
    });

    test('完成（成功）后两个订阅都已取消', () async {
      final future = waitForPlaybackReady(
        duration: duration.stream,
        playing: playing.stream,
      );
      duration.add(const Duration(seconds: 30));
      await future;
      await Future<void>.delayed(Duration.zero);

      expect(duration.hasListener, isFalse);
      expect(playing.hasListener, isFalse);
    });

    test('超时后两个订阅都已取消', () async {
      final future = waitForPlaybackReady(
        duration: duration.stream,
        playing: playing.stream,
        timeout: const Duration(milliseconds: 30),
      );
      await future;
      await Future<void>.delayed(Duration.zero);

      expect(duration.hasListener, isFalse);
      expect(playing.hasListener, isFalse);
    });
  });
}
