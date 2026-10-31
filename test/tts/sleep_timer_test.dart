import 'package:aquan_duanju/core/reader/speech/sleep_timer.dart';
import 'package:flutter_test/flutter_test.dart';

/// SleepTimer 的脱屏单测（design §8）：只依赖显式 tick 与注入时钟，零播放环境。
///
/// 计时口径是「**播放中的墙钟累计**」：只在 tick（正在播）时累加真实时间。
/// 因此「暂停不计时」的断言方式是「不推进时钟直接重入 tick，remaining 纹丝不动」，
/// 而不是看 position。
void main() {
  var nowMs = 0;

  SleepTimer newTimer() => SleepTimer(clockMs: () => nowMs);
  void advance(Duration d) => nowMs += d.inMilliseconds;
  Duration m(int minutes) => Duration(minutes: minutes);

  setUp(() => nowMs = 0);

  group('武装与取消', () {
    test('初始 off：未武装、remaining 为 null、tick 永远 pass', () {
      final t = newTimer();
      expect(t.mode, SleepMode.off);
      expect(t.armed, isFalse);
      expect(t.remaining, isNull);
      expect(t.tick(position: m(5)).stop, isFalse);
    });

    test('武装后立即有完整剩余；剩余随播放墙钟递减，与 position 无关', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      expect(t.armed, isTrue);
      // 不再需要等「首次 tick 的媒体位置基准」——UI 一武装就能显示 30:00。
      expect(t.remaining, m(30));

      t.tick(position: m(10));
      expect(t.remaining, m(30));

      advance(m(2));
      t.tick(position: m(12));
      expect(t.remaining, m(28));

      // position 猛跳（用户拖进度条）不该影响定时长度：只有墙钟走才算。
      t.tick(position: m(9999));
      expect(t.remaining, m(28));
    });

    test('暂停不计时：时钟不推进时 repeated tick 也不扣时间', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 10);
      t.tick(position: m(3));
      final first = t.remaining;
      // 暂停期间宿主不 tick；就算被同位置重入，时钟没走就不许扣。
      for (var i = 0; i < 5; i++) {
        expect(t.tick(position: m(3)).stop, isFalse);
        expect(t.remaining, first);
      }
    });

    test('倍速不影响定时长度：30 分钟就是 30 分钟（墙钟语义回归锁）', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      t.tick(position: Duration.zero);

      // 2 倍速下，30 分钟墙钟对应 60 分钟的媒体位置；这里 position 直接走到 60 分钟，
      // 但墙钟只过了 15 分钟 → 绝不能停。
      advance(m(15));
      expect(t.tick(position: m(60), sentenceEndMs: null).stop, isFalse);
      expect(t.remaining, m(15));

      // 墙钟再走 15 分钟（position 可能只到 90 分钟）→ 这才到点。
      advance(m(15));
      final stop = t.tick(position: m(90), sentenceEndMs: null);
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('setMode(off) 立即失效且可重新武装（重新计时）', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      t.tick(position: m(10));
      advance(m(5));
      t.tick(position: m(15));
      expect(t.remaining, m(25));

      t.setMode(SleepMode.off);
      expect(t.armed, isFalse);
      expect(t.remaining, isNull);
      expect(t.tick(position: m(99)).stop, isFalse); // 取消后怎么都不停

      t.setMode(SleepMode.minutes, minutes: 15);
      expect(t.remaining, m(15), reason: '重新武装必须重新计时，不继承旧 elapsed');
      // 首次 tick 只建时钟基线、不计时（暂停期间没有 tick，自然不能把暂停时长算进去）。
      t.tick(position: m(120));
      advance(m(15));
      expect(t.tick(position: m(135)).stop, isTrue);
    });

    test('fire 后自动失效：恢复播放不会被同一个定时反复停', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 1);
      t.tick(position: Duration.zero, sentenceEndMs: null);
      advance(m(1));
      final fired = t.tick(
        position: m(1),
        sentenceEndMs: null, // 无句边界 → 立即停
      );
      expect(fired.stop, isTrue);
      expect(fired.reason, SleepStopReason.timedOut);
      expect(t.mode, SleepMode.off);
      // 用户按播放恢复：即便 position 还很靠后，也不许立刻再停一次。
      expect(t.tick(position: m(1)).stop, isFalse);
    });
  });

  group('越界输入容错', () {
    test('档位外的自定义分钟数接受', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 25);
      expect(t.minutes, 25);
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
    /// 武装 30 分钟并把墙钟推到刚过 30 分钟（此刻「到点」）。
    SleepTimer armedAndDue() {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      t.tick(position: Duration.zero); // 起算
      advance(m(30));
      return t;
    }

    test('到点且句尾在 30s 内 → 等句尾再停，不硬切', () {
      final t = armedAndDue();
      final target = m(30);
      final wait = t.tick(
        position: target,
        sentenceEndMs: target + const Duration(seconds: 10),
      );
      expect(wait.stop, isFalse, reason: '这句 10s 后念完，等它');
      expect(t.mode, SleepMode.minutes, reason: '等待期间不许失效');

      // 这句念完了，下一句句尾在远处（守卫超窗）→ 立即停。
      final stop = t.tick(
        position: target + const Duration(seconds: 10),
        sentenceEndMs: target + const Duration(minutes: 2),
      );
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('到点但句尾超过 30s → 立即停（按了定时却迟迟不停比切半句更糟）', () {
      final t = armedAndDue();
      final target = m(30);
      final stop = t.tick(
        position: target,
        sentenceEndMs: target + const Duration(seconds: 40),
      );
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('到点且拿不到句边界（音轨路径）→ 立即停', () {
      final t = armedAndDue();
      final stop = t.tick(position: m(30), sentenceEndMs: null);
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('句尾数据已过期（endMs <= position）→ 立即停而不是永不停', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 1);
      t.tick(position: Duration.zero);
      advance(m(1));
      final stop = t.tick(
        position: m(1),
        sentenceEndMs: m(1) - const Duration(seconds: 5),
      );
      expect(stop.stop, isTrue);
      expect(stop.reason, SleepStopReason.timedOut);
    });

    test('未到点时守卫不参与判定（正常播放零打扰）', () {
      final t = newTimer()..setMode(SleepMode.minutes, minutes: 30);
      t.tick(position: Duration.zero);
      advance(m(29));
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

  group('跨宿主恢复（sleepRestoreMinutes）', () {
    test('按真实流逝扣减，向上取整到分钟', () {
      expect(
        sleepRestoreMinutes(
          savedRemainingMs: 30 * 60 * 1000,
          savedAtMs: 0,
          nowMs: 10 * 60 * 1000,
        ),
        20,
      );
      // 还剩 40 秒：宁可多听不到 1 分钟，也不直接停。
      expect(
        sleepRestoreMinutes(savedRemainingMs: 40000, savedAtMs: 0, nowMs: 0),
        1,
      );
    });

    test('已过期 → null（不武装）', () {
      expect(
        sleepRestoreMinutes(
          savedRemainingMs: 60000,
          savedAtMs: 0,
          nowMs: 5 * 60 * 1000,
        ),
        isNull,
      );
      expect(
        sleepRestoreMinutes(savedRemainingMs: 0, savedAtMs: 0, nowMs: 0),
        isNull,
      );
    });

    test('时钟回拨（now < savedAt）不额外扣时间', () {
      expect(
        sleepRestoreMinutes(
          savedRemainingMs: 20 * 60 * 1000,
          savedAtMs: 10 * 60 * 1000,
          nowMs: 0,
        ),
        20,
      );
    });
  });
}
