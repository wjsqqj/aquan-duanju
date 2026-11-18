import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 播放器键盘快捷键的接线证据。
///
/// PlayerScreen 依赖 mpv 引擎与窗口插件，widget 级装配成本过高；这里与
/// `test/widgets/detail_loading_state_test.dart` 同口径，用源码结构断言守住
/// 「PC 上下键切集、电视遥控器保持原语义」这条契约。
void main() {
  String source() => File('lib/screens/player_screen.dart').readAsStringSync();

  test('PC ↑/↓ 切上一集/下一集，电视分支保留音量', () {
    final String code = source();
    final int up = code.indexOf('LogicalKeyboardKey.arrowUp');
    final int down = code.indexOf('LogicalKeyboardKey.arrowDown', up);
    final int keyF = code.indexOf('LogicalKeyboardKey.keyF', down);
    expect(up, greaterThan(0));
    expect(down, greaterThan(up));
    expect(keyF, greaterThan(down));

    final String upBlock = code.substring(up, down);
    final String downBlock = code.substring(down, keyF);

    expect(upBlock, contains('_goPrev(manual: true)'), reason: '↑ = 上一集');
    expect(downBlock, contains('_goNext(manual: true)'), reason: '↓ = 下一集');
    expect(upBlock, contains('_isTv'), reason: '电视遥控器方向键语义不变');
    expect(upBlock, contains('setVolume'),
        reason: '电视上（控制栏隐藏时）仍用 ↑ 调音量');

    // 顺序：PC 分支必须先于 TV 分支，否则电视会被误切集。
    final int pcUp = upBlock.indexOf('!_isTv');
    final int prev = upBlock.indexOf('_goPrev(manual: true)');
    final int tvUpControls = upBlock.indexOf('if (_showControls)');
    final int volumeUp = upBlock.indexOf('setVolume');
    expect(pcUp, greaterThan(0));
    expect(prev, greaterThan(pcUp));
    expect(tvUpControls, greaterThan(prev));
    expect(volumeUp, greaterThan(tvUpControls));

    final int pcDown = downBlock.indexOf('!_isTv');
    final int next = downBlock.indexOf('_goNext(manual: true)');
    final int tvDownControls = downBlock.indexOf('if (_showControls)');
    final int volumeDown = downBlock.indexOf('setVolume');
    expect(pcDown, greaterThan(0));
    expect(next, greaterThan(pcDown));
    expect(tvDownControls, greaterThan(next));
    expect(volumeDown, greaterThan(tvDownControls));

    // 连发保护：PC 分支必须吞掉 KeyRepeat，避免一次长按跳十几次集。
    expect(upBlock, contains('event is KeyRepeatEvent'));
    expect(downBlock, contains('event is KeyRepeatEvent'));
  });

  test('F1 快捷键面板与上下键语义一致', () {
    expect(
      source(),
      contains("_Shortcut(key_: '↑ / ↓', action: '上一集 / 下一集')"),
    );
  });
}
