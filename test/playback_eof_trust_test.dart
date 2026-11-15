import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/playback_eof_trust.dart';

/// `trustPlaybackCompletion` / `durationTruthOk` 的判定矩阵。
///
/// 现场数据来自 2026-11-15 用户日志（60688de 回归）：
/// - 51s 集从 50s 续播、真实前进 1.0s 自然播完 → 被误判异常 EOF → 换线死循环；
/// - 61.3s 集从 45s 续播、真实前进 16.1s 自然播完 → 同样误判。
/// player_screen 侧的接线（_episodeEnded 重置、换线钳制终点前 5s）由
/// analyze + 全量测试回归保障，此处覆盖纯判定分支。
void main() {
  group('trustPlaybackCompletion · 合法播完（AC1）', () {
    test('日志现场 1：51s 集从 50s 续播，服务端真值 51s', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 51.0,
          durationSec: 51.0,
          watchedSec: 1.0,
          serverDurationSec: 51,
          resumeLowerBoundSec: 50,
        ),
        isTrue,
      );
    });

    test('日志现场 2：61.3s 集从 45s 续播，服务端真值 61s', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 61.2,
          durationSec: 61.3,
          watchedSec: 16.1,
          serverDurationSec: 61,
          resumeLowerBoundSec: 45,
        ),
        isTrue,
      );
    });

    test('服务端无真值时续播下限独立放行', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 51.0,
          durationSec: 51.0,
          watchedSec: 1.0,
          resumeLowerBoundSec: 50,
        ),
        isTrue,
      );
    });

    test('新开播全量观看（watched 兜底门禁路径）', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 60,
          durationSec: 60,
          watchedSec: 60,
        ),
        isTrue,
      );
    });

    test('续播贴到末秒（watched<0.5 由 pos≥3 放行）', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 50.8,
          durationSec: 51.0,
          watchedSec: 0.3,
          serverDurationSec: 51,
          resumeLowerBoundSec: 50,
        ),
        isTrue,
      );
    });
  });

  group('trustPlaybackCompletion · 异常 EOF（AC2）', () {
    test('加载不出来：无时长无进度即 completed', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 0,
          durationSec: 0,
          watchedSec: 0,
        ),
        isFalse,
      );
    });

    test('有真实时长但位置从未推进（open 即 completed）', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 0,
          durationSec: 100,
          watchedSec: 0,
          serverDurationSec: 100,
        ),
        isFalse,
      );
    });

    test('续播场景下秒 completed（位置没到终点）', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 0,
          durationSec: 51,
          watchedSec: 0,
          resumeLowerBoundSec: 50,
        ),
        isFalse,
      );
    });

    test('中途夭折：位置距终点 >3s', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 20,
          durationSec: 100,
          watchedSec: 20,
          serverDurationSec: 100,
        ),
        isFalse,
      );
    });
  });

  group('trustPlaybackCompletion · 谎报小时长（AC3/AC4）', () {
    test('服务端真值 100s 引擎只报 20s → 拦截', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 20,
          durationSec: 20,
          watchedSec: 20,
          serverDurationSec: 100,
        ),
        isFalse,
      );
    });

    test('续播下限 45s 引擎只报 20s → 拦截', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 20,
          durationSec: 20,
          watchedSec: 20,
          resumeLowerBoundSec: 45,
        ),
        isFalse,
      );
    });

    test('无任何真值：watched<45 保持 60688de 硬门禁（AC4）', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 20,
          durationSec: 20,
          watchedSec: 20,
        ),
        isFalse,
      );
      expect(
        trustPlaybackCompletion(
          positionSec: 45,
          durationSec: 45,
          watchedSec: 45,
        ),
        isTrue,
        reason: '恰达 45s 门禁放行（语义与 60688de 一致）',
      );
    });
  });

  group('trustPlaybackCompletion · 判定边界', () {
    test('位置容差：恰在 dur-3 处放行，差一点拦截', () {
      bool f(double pos) => trustPlaybackCompletion(
            positionSec: pos,
            durationSec: 100,
            watchedSec: 30,
            serverDurationSec: 100,
          );
      expect(f(97.0), isTrue);
      expect(f(96.9), isFalse);
    });

    test('续播下限 2s 以下不启用（避免几秒的误起点撑出伪下限）', () {
      expect(
        trustPlaybackCompletion(
          positionSec: 45,
          durationSec: 45,
          watchedSec: 10,
          resumeLowerBoundSec: 2,
        ),
        isFalse,
        reason: 'resume=2s 不构成真值，落到 watched<45 兜底',
      );
    });

    test('服务端真值 3s 容差吸收元数据取整', () {
      bool f(double dur) => durationTruthOk(
            durationSec: dur,
            watchedSec: 0,
            serverDurationSec: 61,
            resumeLowerBoundSec: 0,
          );
      expect(f(58.0), isTrue);
      expect(f(57.9), isFalse);
    });
  });

  group('durationTruthOk · 片尾跳过门禁（AC5）', () {
    test('合法短集续播近片尾可跳', () {
      expect(
        durationTruthOk(
          durationSec: 61.3,
          watchedSec: 11,
          serverDurationSec: 61,
          resumeLowerBoundSec: 45,
        ),
        isTrue,
      );
    });
    test('谎报小时长的假推进不可借道连跳', () {
      expect(
        durationTruthOk(
          durationSec: 20,
          watchedSec: 15,
          serverDurationSec: 100,
        ),
        isFalse,
      );
      expect(
        durationTruthOk(
          durationSec: 20,
          watchedSec: 15,
          resumeLowerBoundSec: 45,
        ),
        isFalse,
      );
      expect(
        durationTruthOk(
          durationSec: 20,
          watchedSec: 15,
        ),
        isFalse,
      );
    });

    test('时长未知一律不放行', () {
      expect(
        durationTruthOk(durationSec: 0, watchedSec: 100),
        isFalse,
      );
    });
  });

  group('durationTruthSource · 真值来源观测（日志标注）', () {
    test('三来源按降级链命中', () {
      expect(
        durationTruthSource(
          durationSec: 51.0,
          watchedSec: 1.0,
          serverDurationSec: 51,
          resumeLowerBoundSec: 50,
        ),
        DurationTruthSource.server,
        reason: '服务端真值存在时优先级最高',
      );
      expect(
        durationTruthSource(
          durationSec: 51.0,
          watchedSec: 1.0,
          resumeLowerBoundSec: 50,
        ),
        DurationTruthSource.resumeBound,
      );
      expect(
        durationTruthSource(
          durationSec: 60,
          watchedSec: 60,
        ),
        DurationTruthSource.watchedFallback,
      );
    });

    test('无真值或谎报返回 null（与 durationTruthOk 语义一致）', () {
      expect(durationTruthSource(durationSec: 0, watchedSec: 100), isNull);
      expect(
        durationTruthSource(
          durationSec: 20,
          watchedSec: 20,
          serverDurationSec: 100,
        ),
        isNull,
        reason: '谎报小时长 → null',
      );
      expect(
        durationTruthSource(
          durationSec: 20,
          watchedSec: 20,
        ),
        isNull,
        reason: '无真值且 watched 不足 → null',
      );
    });

    test('durationTruthOk 与 source 判定联动一致', () {
      const cases = [
        (dur: 51.0, watched: 1.0, server: 51, resume: 50.0),
        (dur: 20.0, watched: 20.0, server: 100, resume: 0.0),
        (dur: 45.0, watched: 45.0, server: 0, resume: 0.0),
        (dur: 44.9, watched: 44.9, server: 0, resume: 0.0),
      ];
      for (final c in cases) {
        expect(
          durationTruthOk(
            durationSec: c.dur,
            watchedSec: c.watched,
            serverDurationSec: c.server,
            resumeLowerBoundSec: c.resume,
          ),
          durationTruthSource(
            durationSec: c.dur,
            watchedSec: c.watched,
            serverDurationSec: c.server,
            resumeLowerBoundSec: c.resume,
          ) != null,
          reason: 'dur=${c.dur} watched=${c.watched} server=${c.server}',
        );
      }
    });
  });
}
