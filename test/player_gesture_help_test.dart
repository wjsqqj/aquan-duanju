import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 移动端手势与帮助面板的接线证据。
///
/// PlayerScreen 依赖 mpv 引擎与窗口插件，widget 级装配成本过高；这里沿用
/// `test/widgets/detail_loading_state_test.dart` 的源码结构断言口径，守住：
/// - 竖直滑动 = 上滑下一集 / 下滑上一集（亮度/音量手势已下线）；
/// - 播放器指南按平台分流，移动端不再讲左右半屏亮度/音量；
/// - 快捷键面板按桌面 / TV / 移动三套内容渲染。
void main() {
  String playerSource() =>
      File('lib/screens/player_screen.dart').readAsStringSync();

  String guideSource() =>
      File('lib/widgets/player_guide_dialog.dart').readAsStringSync();

  test('竖直滑动：上滑下一集、下滑上一集，阈值 60dp', () {
    final String source = playerSource();
    final int start = source.indexOf('void _onVerticalDragEnd(');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    final String body = source.substring(start, end);

    expect(body, contains('dy <= -_verticalSwipeThreshold'));
    expect(body, contains('_goNext(manual: true)'));
    expect(body, contains('dy >= _verticalSwipeThreshold'));
    expect(body, contains('_goPrev(manual: true)'));
    expect(source, contains('_verticalSwipeThreshold = 60'));
  });

  test('亮度/音量竖向手势已从播放器下线', () {
    final String source = playerSource();
    expect(source, isNot(contains('_DragKind')));
    expect(source, isNot(contains('ScreenBrightness')));
    expect(source, isNot(contains('volumeFromDrag')));
    expect(source, isNot(contains('_onVerticalDragUpdate')));
  });

  test('快捷键面板按桌面 / TV / 移动分流', () {
    final String source = playerSource();
    final int start = source.indexOf('void _showShortcutHelp()');
    expect(start, greaterThan(0));
    final int end = source.indexOf('\n  }', start);
    final String body = source.substring(start, end);

    expect(body, contains("'键盘快捷键'"));
    expect(body, contains("'手势操作'"));
    expect(body, contains("'遥控器操作'"));
    expect(body, contains('_isDesktop'));
    expect(body, contains('_isTv'));
    // 移动端手势清单
    expect(body, contains("key_: '上滑', action: '下一集'"));
    expect(body, contains("key_: '下滑', action: '上一集'"));
    // 菜单入口文案分流
    expect(source, contains("_isDesktop ? '快捷键' : '操作说明'"));
  });

  test('播放器指南仍按平台分流，移动端改为上下滑切集', () {
    final String source = guideSource();
    final int mobile = source.indexOf('const List<_GuideStep> _mobileSteps');
    final int desktop = source.indexOf('const List<_GuideStep> _desktopSteps');
    expect(mobile, greaterThan(0));
    expect(desktop, greaterThan(0));

    final String mobileBody = source.substring(
      mobile,
      source.indexOf('\n];', mobile),
    );
    final String desktopBody = source.substring(
      desktop,
      source.indexOf('\n];', desktop),
    );

    expect(mobileBody, contains('上滑下一集，下滑上一集'));
    expect(mobileBody, isNot(contains('左半屏调亮度')));
    expect(mobileBody, isNot(contains('右半屏调音量')));
    expect(desktopBody, contains('双击画面切换全屏'));
    expect(source, contains('_desktop ? _desktopSteps : _mobileSteps'));
  });
}
