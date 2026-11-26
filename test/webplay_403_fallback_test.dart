import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「webplay 游客墙 403 必须回落旧接口」的回归（11-19）。
///
/// 用户日志实证：
/// ```
/// 19:32:35 播放 · 打开第8集 startAt=0s（用户选集）
/// 19:32:36 播放 · 打开失败 第8集 · 阶段=解析
///   error=AquaException(WEB_LOGIN_REQUIRED): webplay: login required
///   for this episode: HTTP 403 {"error":"protected_playback_unavailable"}
/// 19:32:53 播放 · 打开第8集 startAt=0s（用户选集）
/// 19:32:55 播放 · 开播 ... 通道=appchain ...
/// ```
/// 也就是：同一集第一次点失败、再点一次（走 appchain）就成功。
///
/// 根因：`_openEpisode` 里遇到 `webLoginRequired` 直接 `rethrow`，
/// 假设「游客墙回落旧接口无效」；但 appchain 明明能取到流。
///
/// 修复：记住该错误先回落 `resolvePlayback`，只有回落也失败才抛游客墙。
void main() {
  final source =
      File('lib/screens/player_screen.dart').readAsStringSync();

  test('webLoginRequired 不再直接 rethrow（先回落旧接口）', () {
    final start = source.indexOf('Future<void> _openEpisode(');
    expect(start, greaterThan(0));
    final end = source.indexOf('Future<void> _playStream(', start);
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, isNot(contains('AquaCode.webLoginRequired) rethrow')),
        reason: '游客墙不得直接 rethrow —— 回落 appchain 实测可取到流');
    expect(body, contains('webLoginError'),
        reason: '应记住游客墙错误，回落也失败时再用它给出准确提示');
    expect(body, contains('await api.resolvePlayback(ep.id)'),
        reason: '游客墙后仍要尝试回落旧接口');
    // 顺序：先 webplay，后回落。
    expect(body.indexOf('resolvePlaybackWeb'),
        lessThan(body.lastIndexOf('resolvePlayback(ep.id)')));
  });

  test('预热两条路径在 webplay 失败时也回落', () {
    for (final fn in ['void _prefetchNext(', 'void _prefetchFirst(']) {
      final start = source.indexOf(fn);
      expect(start, greaterThan(0), reason: '找不到 $fn');
      final end = source.indexOf('\n  }', start);
      final body = source.substring(start, end);
      expect(body, contains('fallback()'),
          reason: '$fn 应把 webplay 失败也接到回落');
      expect(body, contains('onError: (_) => fallback()'),
          reason: '$fn 的 onError 必须回落，否则该集永远预热不中');
    }
  });

  test('解析链失败日志带上诊断附注（v5 失败原因不再丢失）', () {
    // 11-26：整条链都失败时 Go 侧把 v5 原因挂在异常的 diagnostic 上；日志若仍
    // 写 `$e`，原因到不了日志，事后只剩 webplay 的 403。
    final start = source.indexOf('Future<void> _openEpisode(');
    final end = source.indexOf('Future<void> _playStream(', start);
    final body = source.substring(start, end);
    expect(body, contains('回落旧接口: \${errorLogText(e)}'),
        reason: 'webplay 取流失败日志必须带上诊断附注');
    expect(body, isNot(contains(r'回落旧接口: $e')),
        reason: '不得再直接写 \$e（会丢诊断）');

    final feed = File('lib/screens/random_feed_screen.dart').readAsStringSync();
    expect(feed, contains('回落旧接口：\${errorLogText(e)}'),
        reason: '随机播放的取流失败日志同样要带上诊断附注');
  });
}
