import 'dart:async';

import 'launch_command.dart';

/// 进程内命令总线：单实例监听线程（Dart 事件循环）收到命令后投递到这里，
/// 由 App 根组件负责导航。启动早期收到的命令会暂存，等初始化完成再执行。
class CommandBus {
  CommandBus._();

  static final CommandBus instance = CommandBus._();

  final _controller = StreamController<LaunchCommand>.broadcast();
  LaunchCommand? _pending;

  Stream<LaunchCommand> get stream => _controller.stream;

  void emit(LaunchCommand command) {
    if (command.isEmpty) return;
    _pending = command;
    _controller.add(command);
  }

  /// 取走尚未处理的命令（只取一次）。
  LaunchCommand? takePending() {
    final command = _pending;
    _pending = null;
    return command;
  }
}
