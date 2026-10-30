import 'package:aquan_duanju/core/reader/speech/sleep_timer.dart';
import 'package:flutter_test/flutter_test.dart';

/// SleepTimer 的脱屏单测（design §8）：全部只依赖显式 tick 参数，零播放环境。
/// 计时基准是**媒体时间轴**——「暂停不计时」的断言方式是「position 不推进时
/// remaining 不减、到点后反复同 position tick 永远不停」，而不是墙钟。
void main() {
  SleepTimer newTimer() => SleepTimer(clockMs: () => 0);

  Duration m(int minutes) => Duration(minutes: minutes);

  group('武装与取消', () {
    test('初始 off：未武装、remaining 为 null、tick 永远 pass', () {
      final t = newTimer();
      expect(t.mode, SleepMode.off);
      expect(t.armed, isFalse);
      expect(t.remaining, isNull);
      expect(t.tick(position: m(5)).stop, isFalse);
    });

    test('setMode(minutes) 后首次 tick 落零点，remaining 随 position 递减', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      expect(t.armed, isTrue);
      // 还没有媒体位置基准：不猜、不显示。
      expect(t.remaining, isNull);

      t.tick(position: m(10));
      expect(t.remaining, m(30)); // 零点 = 首 tick 的 position

      t.tick(position: m(12));
      expect(t.remaining, m(28));
    });

    test('暂停不计时：position 不推进时 remaining 纹丝不动', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 10);
      t.tick(position: m(3));
      final first = t.remaining;
      // 暂停期间宿主不 tick；就算被同 position 重入，也不许扣时间。
      for (var i = 0; i < 5; i++) {
        expect(t.tick(position: m(3)).stop, isFalse);
        expect(t.remaining, first);
      }
    });

    test('setMode(off) 立即失效且可重新武装（新零点新目标）', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      t.tick(position: m(10));
      t.setMode(SleepMode.off);
      expect(t.armed, isFalse);
      expect(t.remaining, isNull);
      expect(t.tick(position: m(99)).stop, isFalse); // 取消后怎么都不停

      // 重新武装：从新 position 起算。
      t.setMode(SleepMode.minutes, minutes: 15);
      t.tick(position: m(40));
      expect(t.remaining, m(15));
    });

    test('fire 后自动失效：恢复播放不会被同一点反复停', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 1);
      t.tick(position: Duration.zero, sentenceEndMs: null);
      final fired = t.tick(
        position: m(1),
        sentenceEndMs: null, // 无句边界 → 立即停
      );
      expect(fired.stop, isTrue);
      expect(fired.reason, SleepStopReason.timedOut);
      expect(t.mode, SleepMode.off);
      // 用户按播放恢复：position 仍 >= 旧目标，不许立刻再停一次。
      expect(t.tick(position: m(1)).stop, isFalse);
    });
  });

  group('越界输入容错', () {
    test('档位外的自定义分钟数接受', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 25);
      expect(t.minutes, 25);
      t.tick(position: Duration.zero);
      expect(t.remaining, m(25));
    });

    test('minutes <= 0 视为取消（不接受"立刻就会停"的档）', () {
      final zero = newTimer()..setMode(SleepMode.minutes, minutes: 0);
      expect(zero.mode, SleepMode.off);
      expect(zero.armed, isFalse);
      final negative = newTimer()..setMode(SleepMode.minutes, minutes: -5);
      expect(negative.mode, SleepMode.off);
    });

    test('常量档位与守卫上限', () {
      expect(kSleepMinutePresets, <int>[10, 15, 30, 45, 60, 90]);
      expect(kSleepGuardMaxExtra, const Duration(seconds: 30));
    });
  });

  group('句尾守卫（三种情形，design §2）', () {
    SleepTimer armedAt10() =>
        newTimer()..setMode(SleepMode.minutes, minutes: 30);

    test('到点且句尾在 30s 内 → 等句尾再停，不硬切', () {
      final t = armedAt10();
      t.tick(position: Duration.zero);
      final target = m(30);
      final wait = t.tick(
        position: target,
        sentenceEndMs: target + const Duration(seconds: 10),
      );
      expect(wait.stop, isFalse, reason: '这句 10s 后念完，等它');
      expect(t.mode, SleepMode.minutes, reason: '等待期间不许失效');

      // 下一句的句尾在远处（守卫超窗）→ 此刻这句已念完，立即停。
      final stop = t.tick(
        position: target + const Duration(seconds: 10),
        sentenceEndMs: target + const Duration(minutes: 2),
      );
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('到点但句尾超过 30s → 立即停（按了定时却迟迟不停比切半句更糟）', () {
      final t = armedAt10();
      t.tick(position: Duration.zero);
      final target = m(30);
      final stop = t.tick(
        position: target,
        sentenceEndMs: target + const Duration(seconds: 40),
      );
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('到点且拿不到句边界（音轨路径）→ 立即停', () {
      final t = armedAt10();
      t.tick(position: Duration.zero);
      final stop = t.tick(position: m(30), sentenceEndMs: null);
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('句尾数据已过期（endMs <= position）→ 立即停而不是永不停', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 1);
      t.tick(position: Duration.zero);
      final stop = t.tick(
        position: m(1),
        sentenceEndMs: m(1) - const Duration(seconds: 5),
      );
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('未到点时守卫不参与判定（正常播放零打扰）', () {
      final t = armedAt10();
      t.tick(position: Duration.zero);
      final pass = t.tick(
        position: m(29),
        sentenceEndMs: m(29) + const Duration(minutes: 5),
      );
      expect(pass.stop, isFalse);
    });
  });

  group('本章播完停（一次性 + 连播抑制）', () {
    test('未 completed 不停；completed 才 fire 并自动落回 off', () {
      final t = newTimer()..setMode(SleepMode.endOfChapter);
      expect(t.armed, isTrue);
      expect(t.remaining, isNull, reason: '该模式没有剩余时长可言');

      expect(
        t.tick(position: m(5), chapterCompleted: false).stop,
        isFalse,
        reason: 'fire 只发生在 completed 边沿，绝不提前',
      );

      final fire = t.tick(position: m(20), chapterCompleted: true);
      expect(fire.stop, isTrue);
      expect(fire.reason, SleepStopReason.chapterEnd);
      expect(t.mode, SleepMode.off, reason: '一次性：fire 后自动落回 off');
    });

    test('sleepSuppressAutoNext：首次消费为 true，之后恒 false（不隔空误伤）', () {
      final t = newTimer()..setMode(SleepMode.endOfChapter);
      expect(t.sleepSuppressAutoNext, isFalse);
      t.tick(position: m(1), chapterCompleted: true);

      expect(t.sleepSuppressAutoNext, isTrue);
      expect(t.consumeSleepSuppressAutoNext(), isTrue, reason: 'fire 当次抑制连播');
      expect(t.consumeSleepSuppressAutoNext(), isFalse, reason: '只生效一次');
      expect(t.sleepSuppressAutoNext, isFalse);

      // 下一章的 completed 不能再被这次 fire 拦住。
      expect(
        t.tick(position: Duration.zero, chapterCompleted: true).stop,
        isFalse,
      );
      expect(t.consumeSleepSuppressAutoNext(), isFalse);
    });

    test('本组件不引入任何 prefs/控制器依赖：autoNext 持久化键不在可见面内', () {
      // PRD 硬约束「本章播完停不得改写 listen.autoNext」：组件构造只吃一个
      // clockMs，单测里连 SharedPreferences 都不需要——天然写不了那个键。
      final t = SleepTimer(clockMs: () => 123);
      expect(t.clockMs(), 123);
      t.setMode(SleepMode.endOfChapter);
      t.tick(position: Duration.zero, chapterCompleted: true);
      expect(t.mode, SleepMode.off);
    });

    test('setMode 重武装会清掉未消费的抑制位', () {
      final t = newTimer()..setMode(SleepMode.endOfChapter);
      t.tick(position: Duration.zero, chapterCompleted: true);
      t.setMode(SleepMode.minutes, minutes: 10);
      expect(t.sleepSuppressAutoNext, isFalse);
    });
  });
}
