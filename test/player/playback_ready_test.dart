import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player/playback_ready.dart';

void main() {
  group('waitForPlaybackReady', () {
    test('position 前进（真实出画）→ 返回 true', () async {
      final controller = StreamController<Duration>.broadcast();
      final future = waitForPlaybackReady(position: controller.stream);
      controller.add(const Duration(milliseconds: 120));
      expect(await future, isTrue);
      controller.close();
    });

    test('position 一直是 0 不算就绪 → 超时返回 false', () async {
      final controller = StreamController<Duration>.broadcast();
      final future = waitForPlaybackReady(
        position: controller.stream,
        timeout: const Duration(milliseconds: 50),
      );
      controller.add(Duration.zero);
      expect(await future, isFalse);
      controller.close();
    });

    test('无事件 → 超时返回 false', () async {
      final controller = StreamController<Duration>.broadcast();
      final ok = await waitForPlaybackReady(
        position: controller.stream,
        timeout: const Duration(milliseconds: 30),
      );
      expect(ok, isFalse);
      controller.close();
    });

    test('完成后订阅已取消', () async {
      final controller = StreamController<Duration>.broadcast();
      final future = waitForPlaybackReady(position: controller.stream);
      controller.add(const Duration(seconds: 1));
      expect(await future, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasListener, isFalse);
      controller.close();
    });

    test('超时后订阅也已取消', () async {
      final controller = StreamController<Duration>.broadcast();
      final ok = await waitForPlaybackReady(
        position: controller.stream,
        timeout: const Duration(milliseconds: 20),
      );
      expect(ok, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasListener, isFalse);
      controller.close();
    });
  });
}
