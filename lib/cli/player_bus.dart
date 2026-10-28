import 'launch_command.dart';

/// 当前播放器的控制接口：播放器页注册自己，AI / 命令行的播放控制
/// 经这里下达。同一时刻只有一个播放器页在前台链路上。
abstract class PlayerHandle {
  /// kind: pause / resume / toggle / next / prev / status。
  /// 返回值作为单实例通道的回包（status 携带播放状态）。
  Map<String, dynamic> control(String kind);
}

class PlayerBus {
  PlayerBus._();

  static final PlayerBus instance = PlayerBus._();

  PlayerHandle? _handle;

  void attach(PlayerHandle handle) => _handle = handle;

  void detach(PlayerHandle handle) {
    if (identical(_handle, handle)) _handle = null;
  }

  /// 没有播放器时也给一个可读的回包，而不是让 CLI 猜。
  Map<String, dynamic> dispatch(LaunchCommand command) {
    final handle = _handle;
    if (handle == null) {
      return {'ok': true, 'playing': false, 'message': '当前没有在播放'};
    }
    try {
      return handle.control(command.kind);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
