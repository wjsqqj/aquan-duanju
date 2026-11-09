import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/player/playback_buffer_monitor.dart';

/// seek 豁免：拖动进度条/换线续播造成的缓冲不得被判成线路问题。
///
/// 现场：用户拖动 4 次进度条，每次都触发 paused-for-cache；旧实现只在 tick
/// 时跳过 5s，窗口样本仍在，宽限一过立刻命中 `frequentBuffer` → 自动换线，
/// 弹「画面卡顿，换到…」。
void main() {
  group('seek 豁免', () {
    late DateTime now;
    late PlaybackBufferMonitor monitor;

    setUp(() {
      now = DateTime(2026, 11, 9, 21);
      monitor = PlaybackBufferMonitor(clock: () => now);
    });

    void advance(int seconds) => now = now.add(Duration(seconds: seconds));

    test('拖动 4 次缓冲不判频繁换线', () {
      monitor.onOpen();
      monitor.onPlaying();
      for (var i = 0; i < 4; i++) {
        monitor.onSeek();
        monitor.onBuffering(true);
        advance(1);
        monitor.onBuffering(false);
        advance(1);
      }
      // 宽限内不判。
      expect(monitor.tick(), isNull);
      // 宽限结束后，seek 引发的样本已被清洗，不能命中 frequentBuffer。
      advance(11);
      expect(monitor.tick(), isNull);
    });

    test('拖动交互期间完全暂停判定', () {
      monitor.onOpen();
      monitor.onPlaying();
      monitor.beginSeekInteraction();
      monitor.onBuffering(true);
      advance(20);
      expect(monitor.tick(), isNull);

      // 抬手：重新起算宽限，缓冲也从头计时。
      monitor.endSeekInteraction();
      advance(1);
      expect(monitor.tick(), isNull);
      advance(11);
      expect(monitor.tick()?.issue, BufferIssue.longBuffer);
    });

    test('seek 后 10s 内的长缓冲不判', () {
      monitor.onOpen();
      monitor.onPlaying();
      monitor.onSeek();
      monitor.onBuffering(true);
      advance(9);
      expect(monitor.tick(), isNull);
      advance(3);
      expect(monitor.tick()?.issue, BufferIssue.longBuffer);
    });

    test('未发生 seek 的真实频繁缓冲仍然判', () {
      monitor.onOpen();
      monitor.onPlaying();
      for (var i = 0; i < 3; i++) {
        monitor.onBuffering(true);
        advance(1);
        monitor.onBuffering(false);
        advance(5);
      }
      expect(monitor.tick()?.issue, BufferIssue.frequentBuffer);
    });

    test('未发生 seek 的真实累计缓冲仍然判', () {
      monitor = PlaybackBufferMonitor(clock: () => now, frequentCount: 99);
      monitor.onOpen();
      monitor.onPlaying();
      for (var i = 0; i < 6; i++) {
        monitor.onBuffering(true);
        advance(5);
        monitor.onBuffering(false);
        advance(1);
      }
      expect(monitor.tick()?.issue, BufferIssue.accumulatedBuffer);
    });

    test('换线重置清除拖动交互态', () {
      monitor.onOpen();
      monitor.onPlaying();
      monitor.beginSeekInteraction();
      monitor.resetForNewLine();
      monitor.onOpen();
      monitor.onPlaying();
      monitor.onBuffering(true);
      advance(9);
      // 交互态已清：新线路的长缓冲照常判。
      expect(monitor.tick()?.issue, BufferIssue.longBuffer);
    });

    test('起播超时不受 seek 豁免影响', () {
      monitor.onOpen();
      monitor.onSeek();
      advance(16);
      expect(monitor.tick()?.issue, BufferIssue.startupTimeout);
    });

    test('seekGrace 可注入（保留旧口径能力）', () {
      monitor = PlaybackBufferMonitor(
        clock: () => now,
        seekGrace: const Duration(seconds: 5),
      );
      monitor.onOpen();
      monitor.onPlaying();
      monitor.onSeek();
      monitor.onBuffering(true);
      advance(9);
      expect(monitor.tick()?.issue, BufferIssue.longBuffer);
    });
  });
}
