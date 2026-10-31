import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../cast_target.dart';

/// 屏幕镜像状态机（Android 原生 MirrorService 的 Dart 桥）。
///
/// 流程：requestPermission（系统投屏确认框）→ start（起前台服务，等 mirrorStarted
/// 事件拿 /stream.ts URL）→ 面板用该 URL 走既有 DLNA 投屏；服务自毁/致命错误经
/// mirrorStopped 事件回 idle。
class MirrorController extends ChangeNotifier {
  MirrorController._() {
    _channel.setMethodCallHandler(_onEvent);
  }

  static final MirrorController instance = MirrorController._();

  static const _channel = MethodChannel('aquan/cast');
  static const _startTimeout = Duration(seconds: 15);

  MirrorState _state = MirrorState.idle;
  String? _url;
  bool _hasAudio = false;
  String? _lastError;
  Completer<Map<Object?, Object?>>? _startCompleter;

  MirrorState get state => _state;
  String? get url => _url;
  bool get hasAudio => _hasAudio;
  String? get lastError => _lastError;
  bool get isMirroring => _state == MirrorState.mirroring;

  Future<void> _onEvent(MethodCall call) async {
    switch (call.method) {
      case 'mirrorStarted':
        final args = (call.arguments as Map?)?.cast<Object?, Object?>() ?? const {};
        _url = args['url'] as String?;
        _hasAudio = args['audio'] as bool? ?? false;
        _startCompleter?.complete(args);
        _startCompleter = null;
        _state = MirrorState.mirroring;
        notifyListeners();
      case 'mirrorStopped':
        _startCompleter?.completeError(
          CastException('镜像服务停止（${args(call)['reason']}）'),
        );
        _startCompleter = null;
        _state = MirrorState.idle;
        _url = null;
        notifyListeners();
    }
  }

  static Map<Object?, Object?> args(MethodCall call) =>
      (call.arguments as Map?)?.cast<Object?, Object?>() ?? const {};

  /// 请求系统投屏授权；用户拒绝/失败返回 false。
  Future<bool> requestPermission() async {
    try {
      final r = await _channel
          .invokeMethod<Map>('requestMirrorPermission')
          .timeout(const Duration(minutes: 2));
      final granted = r?['granted'] as bool? ?? false;
      if (!granted) {
        _lastError = '未授权屏幕录制';
        notifyListeners();
      }
      return granted;
    } on Exception {
      _lastError = '无法发起屏幕录制授权';
      notifyListeners();
      return false;
    }
  }

  /// 启动镜像服务；返回 /stream.ts URL（失败返回 null，[lastError] 带原因）。
  Future<String?> start({bool withAudio = true}) async {
    if (_state == MirrorState.mirroring || _state == MirrorState.starting) {
      return _url;
    }
    _state = MirrorState.starting;
    _lastError = null;
    notifyListeners();
    final completer = _startCompleter = Completer<Map<Object?, Object?>>();
    try {
      await _channel.invokeMethod<bool>('startMirror', {'withAudio': withAudio});
      final args = await completer.future.timeout(_startTimeout);
      if ((args['url'] as String?)?.isNotEmpty != true) {
        throw CastException('镜像服务未返回地址');
      }
      _lastError = null;
      return _url;
    } on Exception catch (e) {
      _lastError = e is CastException ? e.message : '镜像启动失败';
      _state = MirrorState.idle;
      notifyListeners();
      return null;
    }
  }

  /// 停止镜像服务（投屏会话结束时由 CastController 调用，幂等）。
  Future<void> stop() async {
    if (_state == MirrorState.idle) return;
    _state = MirrorState.stopping;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('stopMirror');
    } on Exception {
      // 服务可能已自毁；等 mirrorStopped 事件兜底。
    }
  }

  /// 测试钩子：直接注入状态（不经过通道）。
  // ignore: avoid_setters_without_getters
  set debugState(MirrorState value) {
    _state = value;
    notifyListeners();
  }
}

enum MirrorState { idle, requesting, starting, mirroring, stopping }
