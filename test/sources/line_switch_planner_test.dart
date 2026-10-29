import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/line_switch_planner.dart';

void main() {
  test('失败 → 换下一条线路；线路尽 → 换下一源；全部尽 → null', () {
    final planner = LineSwitchPlanner(candidates: const [
      SwitchCandidate(key: 'line2'),
      SwitchCandidate(key: 'line3'),
      SwitchCandidate(key: 'src-b', kind: SwitchKind.source),
    ]);

    final d1 = planner.onPlaybackFailed(1000);
    expect(d1?.candidate.key, 'line2');
    expect(d1?.resumeAtMs, 1000);

    planner.consume(d1!.epoch);
    final d2 = planner.onPlaybackFailed(1000);
    expect(d2?.candidate.key, 'line3');

    planner.consume(d2!.epoch);
    final d3 = planner.onPlaybackFailed(1000);
    expect(d3?.candidate.key, 'src-b');
    expect(d3?.candidate.kind, SwitchKind.source);

    planner.consume(d3!.epoch);
    expect(planner.onPlaybackFailed(1000), isNull);
  });

  test('早期窗口内位置前进 → 取消挂起换线（误报），游标复位可再次从 line2 换', () async {
    final planner = LineSwitchPlanner(candidates: const [
      SwitchCandidate(key: 'line2'),
      SwitchCandidate(key: 'line3'),
    ]);
    final d = planner.onPlaybackFailed(1000);
    expect(d?.candidate.key, 'line2');

    // 播放其实在前进：取消挂起并复位。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    planner.onPositionChanged(3000, playing: true);
    final d2 = planner.onPlaybackFailed(3000);
    expect(d2?.candidate.key, 'line2', reason: '取消后游标应复位');
  });

  test('位置未前进（卡在原地）不取消挂起换线', () {
    final planner = LineSwitchPlanner(candidates: const [
      SwitchCandidate(key: 'line2'),
      SwitchCandidate(key: 'line3'),
    ]);
    planner.onPlaybackFailed(1000);
    planner.onPositionChanged(1000, playing: true);
    final d = planner.onPlaybackFailed(1000);
    expect(d?.candidate.key, 'line3');
  });

  test('epoch 递增：旧代回调可被识别并丢弃', () {
    final planner = LineSwitchPlanner(candidates: const [
      SwitchCandidate(key: 'line2'),
      SwitchCandidate(key: 'line3'),
    ]);
    final d1 = planner.onPlaybackFailed(0);
    final oldEpoch = d1!.epoch;
    final d2 = planner.onPlaybackFailed(0);
    expect(d2!.epoch, isNot(oldEpoch));
    // 旧代 consume 不影响新一代的挂起状态。
    planner.consume(oldEpoch);
    expect(planner.epoch, d2.epoch);
  });
}
