/// 媒体会话的**唯一桥**：把系统命令派发给「当前在播的那个宿主」。
///
/// 为什么需要它：`audio_service` 只有一个 handler 入口，而本工程有两条并行播放路径
/// （`ReaderSpeechController` 与独立听书页 `book_audio_screen`，既有技术债，见
/// `listen-tts-contract.md`）。桥让「谁在播谁接命令」，避免两条路径抢同一个 handler，
/// 也不必长出第三份播放实现（design §4）。
library;

import 'listen_media_session.dart';
import 'listen_media_state.dart';

/// 宿主命令处理器。`position` 只在 `seekTo` 时有意义。
typedef ListenHandler = void Function(
  ListenMediaCommand cmd,
  Duration? position,
);

class ListenMediaBridge {
  ListenMediaBridge(this._session) {
    // 命令上抛口在构造时就接上：会话不认识桥，桥负责派发。
    _session.onCommand = dispatch;
  }

  /// 进程级实例：`main.dart` 在 Android 上装配一次；测试直接 `new` 一个即可。
  static ListenMediaBridge? instance;

  final ListenMediaSession _session;

  ListenHandler? _handler;
  bool _disposed = false;

  ListenHandler? get handler => _handler;

  bool get hasHandler => _handler != null;

  /// 宿主开始播放时调用。**幂等**：同一次宿主重复 attach 无副作用。
  void attach(ListenHandler handler) {
    if (_disposed) return;
    _handler = handler;
  }

  /// 宿主销毁时调用。**只有当前挂着的就是它才清空** —— 否则「新页先 attach、
  /// 旧页后 dispose」会把新宿主的回调擦掉（Flutter 页面切换的典型顺序）。
  void detach(ListenHandler handler) {
    if (identical(_handler, handler)) _handler = null;
  }

  /// 会话回调入口（也供测试直接驱动）。
  void dispatch(ListenMediaCommand cmd, Duration? position) {
    if (_disposed) return;
    final handler = _handler;
    // 没有宿主在播：静默丢弃。后台按了通知键不该崩。
    if (handler == null) return;
    // seekTo 没带位置是无意义命令：宁可丢弃，也别跳回 0 把人送回章节开头。
    if (cmd == ListenMediaCommand.seekTo && position == null) return;
    try {
      handler(cmd, position);
    } catch (_) {
      // 宿主内部异常不能冒到平台通道（会让通知键无响应且日志难查）。
    }
  }

  Future<void> publish(ListenMediaState state) async {
    if (_disposed) return;
    try {
      await _session.publish(state);
    } catch (_) {
      // 媒体会话失败绝不影响播放（design §4）。
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handler = null;
    try {
      await _session.dispose();
    } catch (_) {}
    if (identical(instance, this)) instance = null;
  }

  /// 平台装配入口：非 Android（返回 Noop 会话）时给 `null`，
  /// 调用方据此完全不参与媒体会话，Windows 上零开销、零异常。
  static Future<ListenMediaBridge?> ensure() async {
    final existing = instance;
    if (existing != null) return existing;
    final session = createListenMediaSession();
    if (session is NoopListenMediaSession) return null;
    return instance = ListenMediaBridge(session);
  }
}
