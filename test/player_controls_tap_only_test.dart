import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PC 端控制栏显隐与指针可见性的契约回归（11-19）。
///
/// 用户反馈：单击视频后控制栏与鼠标一起消失；鼠标一动，控制栏也跟着
/// 出现。要求改为：
/// 1) 控制栏**只**由单击视频切换显隐 —— 鼠标移动不得呼出控制栏；
/// 2) 指针显隐与控制栏显隐**解耦** —— 控制栏隐藏时鼠标移动仍让指针可见，
///    指针静止约 3 秒后再次消失。
///
/// 注：11-18 的 A10 曾是「onHover 恢复控制栏」，与本需求冲突，
/// 已按用户新需求改写（spec: card-menu-and-episode-segment-contract）。
void main() {
  final source =
      File('lib/screens/player_screen.dart').readAsStringSync();

  test('鼠标移动不再呼出控制栏（无 hover → _showControls = true 的路径）', () {
    expect(source, isNot(contains('void _bumpControls()')),
        reason: '旧的 hover 呼出控制栏入口应已移除');
    // 隐藏态的 hover 不得改 _showControls。
    final bumpStart = source.indexOf('void _bumpPointer()');
    expect(bumpStart, greaterThan(0));
    final end = source.indexOf('void _schedulePointerHide()', bumpStart);
    final body = source.substring(bumpStart, end);
    expect(body, isNot(contains('_showControls = true')),
        reason: 'hover 不得把控制栏置为可见');
    expect(body, contains('_pointerVisible = true'),
        reason: 'hover 只负责恢复指针可见');
  });

  test('指针可见性与控制栏显隐解耦（独立状态）', () {
    expect(source, contains('bool _pointerVisible'));
    expect(source, contains('Timer? _pointerHideTimer'));
    // cursor 由 _pointerVisible 决定，而不是 _showControls。
    final wrapStart = source.indexOf('Widget _wrapDesktopPointer');
    expect(wrapStart, greaterThan(0));
    final end = source.indexOf('final SurfaceTapArbiter', wrapStart);
    final body = source.substring(wrapStart, end);
    expect(body, contains('_pointerVisible ? MouseCursor.defer'));
    expect(body, isNot(contains('_showControls ? MouseCursor.defer')),
        reason: '指针显隐不得再直接绑定控制栏显隐');
  });

  test('单击视频仍是控制栏显隐的唯一入口', () {
    final tapStart = source.indexOf('void _onSurfaceTap()');
    expect(tapStart, greaterThan(0));
    final end = source.indexOf('void _startSeekRepeat', tapStart);
    final body = source.substring(tapStart, end);
    expect(body, contains('_toggleControls()'));
    // 双击撤销第一次显隐后走全屏，仍不改「单击才切换」的语义。
    expect(body, contains('_toggleControls(); // 撤销第一次单击的显隐'));
  });

  test('指针静止若干秒后隐藏（控制栏隐藏态才生效）', () {
    final start = source.indexOf('void _schedulePointerHide()');
    expect(start, greaterThan(0));
    final end = source.indexOf('Widget _wrapDesktopPointer', start);
    final body = source.substring(start, end);
    expect(body, contains('Timer(const Duration(seconds: 3)'));
    expect(body, contains('if (_showControls) return'),
        reason: '控制栏可见时指针不应单独隐藏');
    expect(body, contains('_pointerVisible = false'));
  });

  test('控制栏显示时指针必须可见（控件要能点）', () {
    final start = source.indexOf('void _toggleControls()');
    expect(start, greaterThan(0));
    final end = source.indexOf('void _bumpPointer()', start);
    final body = source.substring(start, end);
    expect(body, contains('_pointerVisible = true'),
        reason: '控制栏可见时指针必须可见');
    expect(body, contains('_schedulePointerHide()'),
        reason: '控制栏收起后指针按鼠标活动决定可见性');
  });

  test('命中契约不破：MouseRegion 仍 opaque:false 且不发 onDoubleTap', () {
    final wrapStart = source.indexOf('Widget _wrapDesktopPointer');
    final end = source.indexOf('final SurfaceTapArbiter', wrapStart);
    final body = source.substring(wrapStart, end);
    expect(body, contains('opaque: false'),
        reason: 'opaque:true 会吃掉下层点击（player-overlay-hit-contract）');
    expect(body, isNot(contains('onDoubleTap')));
  });
}
