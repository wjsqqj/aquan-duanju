import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// issue #2（切集后倍速丢失）的接线证据。
///
/// 与 `test/player_shortcut_keys_test.dart` 同口径：PlayerScreen 依赖 mpv 引擎
/// 与窗口插件，widget 级装配成本过高；这里用源码结构断言守住
/// 「开播 / 换集 / 换线 / 缓存播放 / 弹幕都经 `_effectiveRate`」这条契约。
///
/// 回归背景：`5ed9280` 起三处开播写成 `setRate(_holdSpeed.rate)`，未长按时
/// `HoldSpeedState.rate` 就是默认 `baseRate = 1.0`，任何一次开播都把引擎
/// 速率写回 1x（UI 仍显示 1.5x）。
void main() {
  String source() => File('lib/screens/player_screen.dart').readAsStringSync();

  /// 取 [start]（含）到 [end] 之间的源码切片，[end] 是下一个成员的起点。
  String body(String code, String start, String end) {
    final int from = code.indexOf(start);
    expect(from, greaterThanOrEqualTo(0), reason: '找不到起点 $start');
    final int to = code.indexOf(end, from + start.length);
    expect(to, greaterThan(from), reason: '找不到终点 $end');
    return code.substring(from, to);
  }

  test('不再把 _holdSpeed.rate 直接写进引擎（未长按时它恒为 1.0）', () {
    expect(source(), isNot(contains('setRate(_holdSpeed.rate)')));
  });

  test('三处开播都在 open 前后写入实际生效倍速', () {
    final String code = source();
    final Map<String, String> bodies = <String, String>{
      '_playStream': body(
        code,
        'Future<void> _playStream(',
        'Future<void> _openUrl(',
      ),
      '_openUrl': body(code, 'Future<void> _openUrl(', 'void _prefetchNext('),
      '_playLocal': body(
        code,
        'Future<void> _playLocal(',
        'Future<void> _switchDefinition(',
      ),
    };

    for (final MapEntry<String, String> entry in bodies.entries) {
      final String block = entry.value;
      final int calls = RegExp(r'setRate\(_effectiveRate\)')
          .allMatches(block)
          .length;
      expect(
        calls,
        greaterThanOrEqualTo(2),
        reason: '${entry.key} 需要在 open 前后各写一次倍速（防内核 load 重置）',
      );

      final int first = block.indexOf('setRate(_effectiveRate)');
      final int open = block.indexOf('_engine.open(');
      final int last = block.lastIndexOf('setRate(_effectiveRate)');
      expect(open, greaterThan(first), reason: '${entry.key} 开播前先设速率');
      expect(last, greaterThan(open), reason: '${entry.key} open 后再补一次');
    }
  });

  test('弹幕时间轴用实际播放倍速（锁定 2x 时同步加速）', () {
    final String code = source();
    expect(code, contains('rate: _effectiveRate'));
    expect(code, isNot(contains('rate: _speed,')));
  });

  test('_effectiveRate 由 HoldSpeedState.effectiveRate 派生，显示值复用它', () {
    final String code = source();
    expect(code, contains('double get _effectiveRate'));
    expect(code, contains('_holdSpeed.effectiveRate(_speed)'));
    expect(code, contains('double get _displaySpeed => _effectiveRate;'));
  });

  // 首次开播也要吃到倍速（issue #2 的另一半根因）：initState 必须先按
  // 「按剧记忆 > 全局默认」定好 _speed，再经 _openEpisode → _playStream/_playLocal
  // 开播；否则引擎会先以 1.0x 起播，UI 却显示历史倍速。
  test('首次开播：initState 先定倍速，再走 _openEpisode → _playStream/_playLocal', () {
    final String code = source();
    final String initState = body(
      code,
      'void initState()',
      'void didChangeDependencies()',
    );
    final int prefsRead = initState.indexOf('prefs.speed > 0');
    final int firstPlay = initState.indexOf('_openEpisode(');
    expect(prefsRead, greaterThanOrEqualTo(0), reason: 'initState 应读取按剧记忆倍速');
    expect(initState, contains('settings.defaultSpeed'),
        reason: '无按剧记忆时回落全局默认倍速');
    expect(firstPlay, greaterThan(prefsRead), reason: '必须先定倍速再起播');

    final String episode = body(
      code,
      'Future<void> _openEpisode(',
      'void _schedulePlaybackAutoRetry()',
    );
    expect(episode, contains('_playStream('), reason: '网络集首次开播走 _playStream');
    expect(episode, contains('_playLocal('), reason: '已缓存集首次开播走 _playLocal');
  });

  // 跨季自动连播/选集换季走 pushReplacement 新建 PlayerScreen：必须把当前
  // 用户档位传过去，否则新页按新 seriesId 读偏好/默认，倍速再次丢失。
  test('跨季换页继承当前用户倍速（不把长按 2x 当偏好）', () {
    final String code = source();
    final String season = body(
      code,
      'Future<void> _openSeasonEpisode(',
      'void _goPrev(',
    );
    expect(season, contains('initialSpeed: _speed'));
    expect(season, isNot(contains('initialSpeed: _effectiveRate')),
        reason: '跨页只传用户档位，锁定 2x 属临时态');
    expect(code, contains('widget.initialSpeed ??'),
        reason: '新页应优先使用传入档位');
  });

  // 售后/用户核验口：开播日志必须写出实际写入引擎的速率（换集后看下一集
  // 的「开播」行即可确认是否继承，不必只凭听感判断）。
  test('开播日志记录实际生效速率', () {
    expect(
      source(),
      contains(r'rate=${_trimSpeed(_effectiveRate)}x'),
    );
  });

  // 排障口：倍速被改成 2x 时，日志要能区分菜单/键盘/CLI/长按，避免「谁改的」
  // 只能靠猜（issue #2 追问「第11集为什么是 2x」）。
  test('倍速变更记录来源（菜单/键盘/CLI/长按）', () {
    final String code = source();
    expect(code, contains(r'倍速 ${_trimSpeed(v)}x（来源：$source）'));
    expect(code, contains("source: '键盘'"));
    expect(code, contains("source: 'CLI'"));
    expect(code, contains('长按倍速：按下'));
    expect(code, contains('长按倍速：锁定 2x'));
    expect(code, contains('长按倍速：打断'));
  });
}
