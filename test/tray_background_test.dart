import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 托盘后台 + 轻量模式 + 进度节流的接线证据。
///
/// HomeScreen 依赖真实窗口/托盘插件，widget 级装配成本过高；这里与
/// `test/player_shortcut_keys_test.dart` 同口径，用源码结构断言守住契约：
/// 托盘「退出」必须真 destroy、轻量模式必须停帧、进度必须节流。
void main() {
  String source(String path) => File(path).readAsStringSync();

  test('HomeScreen 混入 TrayListener，退出菜单真退出', () {
    final String code = source('lib/screens/home_screen.dart');
    expect(code, contains('with WindowListener, TrayListener'));
    expect(code, contains("MenuItem(key: 'show_window'"));
    expect(code, contains("MenuItem(key: 'exit_app'"));
    expect(code, contains('windowManager.destroy()'));
    expect(code, contains('trayManager.setContextMenu'));
    // window_manager 默认不拦 WM_CLOSE：不 preventClose 则 X 直接退出，
    // onWindowClose 里的「收进托盘」根本来不及生效（用户实测）。
    expect(
      code,
      contains('windowManager.setPreventClose(true)'),
      reason: '必须拦截关闭按钮，否则托盘后台不可用',
    );
    // tray_manager 0.5.x 右键只发事件不弹菜单：缺这句则「退出」菜单永远点不到。
    expect(
      code,
      contains('trayManager.popUpContextMenu()'),
      reason: '右键必须弹出上下文菜单，否则退出项不可达',
    );
    expect(
      code,
      contains("PlayerBus.instance.dispatch(LaunchCommand.parse(['--pause']))"),
      reason: '进入轻量模式必须复用既有暂停命令',
    );
  });

  test('退出时先删托盘图标再关窗（幽灵图标回归）', () {
    final String code = source('lib/screens/home_screen.dart');
    expect(code, contains('Future<void> _exitApp()'));
    final int trayDestroy = code.indexOf('await trayManager.destroy()');
    final int windowDestroy =
        code.indexOf('await windowManager.destroy()', trayDestroy + 1);
    expect(trayDestroy, greaterThan(0), reason: '退出路径必须显式删除托盘图标');
    expect(windowDestroy, greaterThan(trayDestroy),
        reason: '必须先删图标再关窗，否则 Shell 留下幽灵图标');
  });

  test('主入口停帧、下载节流、设置开关齐备', () {
    final String main = source('lib/main.dart');
    // 分开断言，避免换行/缩进调整让结构测试误报（只看契约，不锁排版）。
    expect(main, contains('TickerMode('), reason: '轻量模式必须关闭全局 Ticker');
    expect(
      main,
      contains('enabled: !widget.settings.lightweightActive'),
      reason: 'TickerMode 必须受轻量模式开关控制',
    );

    final String download = source('lib/core/download_service.dart');
    expect(download, contains('kProgressThrottleMs = 200'));

    final String mine = source('lib/screens/mine_screen.dart');
    expect(mine, contains('关闭窗口时收进托盘'));
    expect(mine, contains('最小化时收进托盘'));
    expect(mine, contains('收进托盘时进入轻量模式'));
  });
}
