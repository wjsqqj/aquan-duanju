import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 红果漫剧首播卡顿的回归（11-19）。
///
/// 用户反馈：刚进入红果漫剧视频观看时有 1~2 秒卡顿感。
///
/// 根因（两处，均在本仓可控范围内）：
/// 1) `Video` widget 被 `_prepared` 硬门控 —— 等 `engine.open()` +
///    `_seekResume()` 跑完才挂载，这段窗口画面纯黑；
/// 2) 首集取流要等 `_openEpisode` 才发起（页面构建完成后），转场动画
///    期间完全没在取流。
///
/// 修复：Video 常驻 + 未就绪时叠黑幕；进页即预解析首集（`_prefetched`
/// 命中则 `_openEpisode` 零等待）。
void main() {
  final source =
      File('lib/screens/player_screen.dart').readAsStringSync();

  test('Video 不再被 _prepared 硬门控（首帧不等 open 完成）', () {
    final buildVideo =
        source.indexOf('Widget _buildVideo(BuildContext context)');
    expect(buildVideo, greaterThan(0));
    final end = source.indexOf('/// 桌面「铺满」', buildVideo);
    expect(end, greaterThan(buildVideo));
    final body = source.substring(buildVideo, end);
    // 旧实现：`if (!_prepared) { return Container(color: videoBlack); }`
    // —— Video 根本不建树（首播黑屏）。新实现不得再有这种早退。
    expect(body, isNot(contains('return Container(')),
        reason: 'Video 不得再因 _prepared 早退（首播黑屏 1~2 秒）');
    expect(body, contains('Video('));
    // 未就绪时用黑幕覆盖在 Video 之上，而不是不挂载。
    expect(body, contains('if (!_prepared)'));
    expect(body,
        contains('ColoredBox(color: PlayerOverlayTokens.videoBlack)'));
    // Video 必须排在黑幕之前（黑幕是后加的覆盖层）。
    expect(body.indexOf('Video('),
        lessThan(body.indexOf('if (!_prepared)')));
  });

  test('进页即预解析首集，与页面转场并行', () {
    expect(source, contains('void _prefetchFirst()'));
    final init = source.indexOf('void initState()');
    final initEnd = source.indexOf('void didChangeDependencies()', init);
    final body = source.substring(init, initEnd);
    expect(body, contains('_prefetchFirst()'),
        reason: '首集取流必须在 initState 就挂上，不能等 _openEpisode');
    // 预热与开挂并行：预热在前、开挂在后。
    expect(body.indexOf('_prefetchFirst()'),
        lessThan(body.indexOf('_openEpisode(')));
  });

  test('预热失败静默，且复用既有 _prefetched 缓存机制', () {
    final start = source.indexOf('void _prefetchFirst()');
    expect(start, greaterThan(0));
    final end = source.indexOf('// ---------- 弹幕 ----------', start);
    final body = source.substring(start, end);
    expect(body, contains('onError: (_) {}'),
        reason: '预热失败必须静默，不能影响正常起播');
    expect(body, contains('_prefetched[_index] = pb'));
    // 复用既有命中机制：_openEpisode 取 _prefetched 且校验有效期。
    expect(source, contains('prefetchUsable(cached, DateTime.now())'));
  });

  test('_prepared 语义不变（仍是「已开播」），错误面板与手势分层不受影响', () {
    // 弹幕层与缓冲徽标仍按 _prepared 门控（未开播不该显示）。
    expect(source, contains('_prepared '), reason: '弹幕层仍受 _prepared 门控');
    expect(source, contains('_danmakuOn'));
    // 错误面板仍压在控制栏之上（player-overlay-hit-contract）。
    // 不绑定具体 if 条件文本（PiP 期间会追加 `!_inPip` 守卫），只锁顺序。
    final controls = source.indexOf('_buildControls(context)');
    final loadError = source.indexOf('_buildLoadError(context)');
    expect(controls, greaterThan(0));
    expect(loadError, greaterThan(controls),
        reason: '错误面板必须排在控制栏之后（命中优先级更高）');
  });
}
