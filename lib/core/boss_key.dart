import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../cli/launch_command.dart';
import '../cli/player_bus.dart';
import 'error_log.dart';

/// 桌面「老板键」：全局热键 `Ctrl+Shift+H` 隐藏窗口并暂停播放，再按恢复。
///
/// 原生侧（`windows/runner/flutter_window.cpp`）负责 `RegisterHotKey`，命中后
/// 通过 `aquan/boss_key` 通道回调 `toggle`；Dart 侧只管窗口与播放状态。
///
/// 安全约束：**热键注册失败时绝不隐藏窗口**——否则窗口藏起来又没有任何全局
/// 入口可以唤回，用户只能杀进程。托盘菜单是另一条兜底通道。
class BossKeyService {
  BossKeyService._();

  static final BossKeyService instance = BossKeyService._();

  static const MethodChannel _channel = MethodChannel('aquan/boss_key');

  bool _initialized = false;

  /// 原生是否真的注册成功（被其它程序占用时为 false）。
  bool _available = false;
  bool _hidden = false;
  bool _resumeOnShow = false;

  /// 启动时调一次；[enabled] 来自设置项 `ui.bossKey`。
  Future<void> init({required bool enabled}) async {
    if (!Platform.isWindows) return;
    if (_initialized) {
      await setEnabled(enabled);
      return;
    }
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'toggle') await toggle();
      return null;
    });
    _initialized = true;
    await setEnabled(enabled);
  }

  /// 开关切换 / 启动同步。返回原生是否注册成功。
  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows || !_initialized) return false;
    try {
      final bool? ok =
          await _channel.invokeMethod<bool>('setEnabled', enabled);
      _available = enabled && (ok ?? false);
      if (enabled && !_available) {
        ErrorLog.instance
            .record('老板键', 'Ctrl+Shift+H 注册失败（可能被其它程序占用）');
      }
    } catch (e) {
      _available = false;
      ErrorLog.instance.record('老板键', '注册/注销失败：$e');
    }
    return _available;
  }

  /// 隐藏/恢复。隐藏期间暂停播放，恢复后仅在隐藏前确实在播时继续。
  Future<void> toggle() async {
    try {
      if (!_hidden) {
        if (!_available) return; // 热键不可用：不隐藏，避免无法唤回
        final Map<String, dynamic> status =
            PlayerBus.instance.dispatch(_cmd('status'));
        _resumeOnShow = status['playing'] == true;
        if (_resumeOnShow) {
          PlayerBus.instance.dispatch(_cmd('pause'));
        }
        await windowManager.hide();
        _hidden = true;
        ErrorLog.instance.record('老板键', '窗口已隐藏（播放${_resumeOnShow ? '暂停' : '未在播'}）');
      } else {
        await windowManager.show();
        await windowManager.focus();
        _hidden = false;
        if (_resumeOnShow) {
          PlayerBus.instance.dispatch(_cmd('resume'));
        }
        _resumeOnShow = false;
        ErrorLog.instance.record('老板键', '窗口已恢复');
      }
    } catch (e, st) {
      ErrorLog.instance.record('老板键', '切换失败：$e', st);
    }
  }
}

/// `LaunchCommand` 的构造器是私有的，统一用 `parse` 造播放控制命令，
/// 避免为了三个常量去动 CLI 模块的公开 API。
LaunchCommand _cmd(String kind) => LaunchCommand.parse(<String>[kind]);
