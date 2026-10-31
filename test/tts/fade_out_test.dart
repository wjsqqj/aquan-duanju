import 'package:aquan_duanju/core/reader/speech/fade_out.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> noSleep(Duration _) async {}

  test('线性降音到 0：步数与取值都确定', () async {
    final volumes = <double>[];
    final ok = await runVolumeFadeOut(
      steps: 4,
      durationMs: 400,
      setVolume: (v) async => volumes.add(v),
      sleep: noSleep,
    );
    expect(ok, isTrue);
    expect(volumes, <double>[0.75, 0.5, 0.25, 0.0]);
  });

  test('可取消：isCurrent 变 false 后不再碰播放器', () async {
    var current = true;
    final volumes = <double>[];
    final ok = await runVolumeFadeOut(
      steps: 4,
      durationMs: 400,
      setVolume: (v) async {
        volumes.add(v);
        if (volumes.length == 2) current = false;
      },
      sleep: noSleep,
      isCurrent: () => current,
    );
    expect(ok, isFalse);
    expect(volumes.length, 2);
  });

  test('durationMs / steps 非正：直接返回且一次都不调音量', () async {
    var calls = 0;
    final ok1 = await runVolumeFadeOut(
      durationMs: 0,
      setVolume: (_) async {
        calls++;
      },
    );
    final ok2 = await runVolumeFadeOut(
      steps: 0,
      setVolume: (_) async {
        calls++;
      },
    );
    expect(ok1, isTrue);
    expect(ok2, isTrue);
    expect(calls, 0);
  });

  test('from 为 0 时按满音量处理，否则淡出等于静音', () async {
    final volumes = <double>[];
    await runVolumeFadeOut(
      from: 0,
      steps: 2,
      durationMs: 200,
      setVolume: (v) async => volumes.add(v),
      sleep: noSleep,
    );
    expect(volumes.first, 0.5);
    expect(volumes.last, 0.0);
  });

  test('默认参数落在合理区间（3 秒、10 步）', () {
    expect(kSleepFadeOutMs, 3000);
    expect(kSleepFadeOutSteps, 10);
  });
}
