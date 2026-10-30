import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cast_controller.dart';
import '../cast_target.dart';
import 'castv2_channel.dart';
import 'proto/cast_channel.dart';

/// Chromecast CASTv2 传输实现（Default Media Receiver）。
///
/// 会话序列（dart_cast/playbridge 同款）：TLS 连接 → CONNECT(receiver-0) →
/// 心跳 PING → LAUNCH(CC1AD845) → 等 RECEIVER_STATUS 拿 transportId →
/// CONNECT(transportId) → LOAD/PLAY/PAUSE/SEEK/STOP/SET_VOLUME/GET_STATUS。
/// 每个 namespace 都要先 CONNECT，否则消息被设备静默丢弃。
class ChromecastTransport implements CastTransport {
  ChromecastTransport(
    this.device, {
    CastV2Channel? channel,
    this.readyTimeout = const Duration(seconds: 8),
  }) : _channel = channel ?? CastV2Channel();

  static const _nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
  static const _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const _nsMedia = 'urn:x-cast:com.google.cast.media';
  static const _appId = 'CC1AD845'; // Default Media Receiver
  static const _senderId = 'sender-0';
  static const _receiverId = 'receiver-0';

  /// 设备回错误帧的类型集合（不以 ERROR 结尾的 LOAD_FAILED 单列）。
  static const _errorTypes = {
    'LOAD_FAILED',
    'LAUNCH_ERROR',
    'INVALID_REQUEST',
    'AUTHENTICATION_ERROR',
    'CANCELLED',
  };

  final CastDeviceInfo device;
  final CastV2Channel _channel;
  final Duration readyTimeout;

  int _requestId = 0;
  bool _connected = false;
  String? _transportId;
  String? _appSessionId;
  int? _mediaSessionId;

  final _mediaStatusWaiters = <int, Completer<Map<String, dynamic>>>{};
  final _receiverStatusWaiters = <int, Completer<Map<String, dynamic>>>{};
  Timer? _heartbeat;
  StreamSubscription<CastMessage>? _messageSub;

  // ---------------------------------------------------------------------------
  // 连接与应用会话
  // ---------------------------------------------------------------------------

  Future<void> _ensureConnected() async {
    if (_connected) return;
    await _channel.connect(device.host, port: device.port);
    _messageSub = _channel.messageStream.listen(_onMessage);
    _send(_nsConnection, _receiverId, {'type': 'CONNECT', 'origin': {}});
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      _safeSend(_nsHeartbeat, _receiverId, {'type': 'PING'});
    });
    _connected = true;
  }

  /// LAUNCH 应用并就绪：拿到 transportId + media 会话（若已在播）。
  Future<void> _ensureLaunched() async {
    if (_transportId != null) return;
    final status = await _requestReceiverStatus(
      {'type': 'LAUNCH', 'requestId': _nextId(), 'appId': _appId},
    );
    final apps = status['applications'];
    if (apps is! List || apps.isEmpty) {
      throw CastException('Chromecast 应用启动失败（接收器无应用会话）');
    }
    final app = apps.first as Map<String, dynamic>;
    _transportId = app['transportId'] as String?;
    _appSessionId = app['sessionId'] as String?;
    if (_transportId == null || _transportId!.isEmpty) {
      throw CastException('Chromecast 应用启动失败（缺 transportId）');
    }
    // CONNECT 到应用会话：media namespace 消息必须发到这里。
    _send(_nsConnection, _transportId!, {'type': 'CONNECT', 'origin': {}});
    // 已有媒体会话（上次投的还在播）→ 记下来，避免 LOAD 时重复起会话。
    final media = await _requestMediaStatus({
      'type': 'GET_STATUS',
      'requestId': _nextId(),
    });
    final existing = media['mediaSessionId'];
    if (existing is int) _mediaSessionId = existing;
  }

  // ---------------------------------------------------------------------------
  // CastTransport
  // ---------------------------------------------------------------------------

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    await _ensureConnected();
    await _ensureLaunched();
    // 上一个媒体会话还在（换集连投）：先 STOP 清掉，保证 LOAD 起新会话。
    if (_mediaSessionId != null) {
      await _mediaCommand({'type': 'STOP', 'mediaSessionId': _mediaSessionId});
      _mediaSessionId = null;
    }
    final media = <String, dynamic>{
      'contentId': url.toString(),
      'streamType': 'BUFFERED',
      'contentType': _guessMime(url),
      'metadata': {'metadataType': 0, 'title': title},
    };
    if (subtitleUrl != null) {
      // 外挂字幕：Chromecast 只认 WebVTT（SRT 由上游转换后投进来）。
      media['textTracks'] = [
        {
          'trackId': 1,
          'type': 'TEXT',
          'subtype': 'captions',
          'contentId': subtitleUrl.toString(),
          'language': 'zh',
          'name': '字幕',
        }
      ];
    }
    final payload = <String, dynamic>{
      'type': 'LOAD',
      'requestId': _nextId(),
      'media': media,
      'autoplay': true,
    };
    if (subtitleUrl != null) payload['activeTrackIds'] = [1];
    final status = await _requestMediaStatus(payload, timeout: readyTimeout);
    final mediaSessionId = status['mediaSessionId'];
    final playerState = status['playerState'] as String? ?? '';
    if (mediaSessionId == null &&
        (playerState == 'IDLE' || playerState.isEmpty)) {
      throw CastException(
          'Chromecast LOAD 失败（${status['idleReason'] ?? '无媒体会话'}）');
    }
    if (mediaSessionId is int) _mediaSessionId = mediaSessionId;
  }

  @override
  Future<void> play() async {
    await _mediaCommand({'type': 'PLAY', 'mediaSessionId': _mediaSessionId});
  }

  @override
  Future<void> pause() async {
    await _mediaCommand({'type': 'PAUSE', 'mediaSessionId': _mediaSessionId});
  }

  @override
  Future<void> stop() async {
    if (_mediaSessionId != null) {
      try {
        await _mediaCommand({'type': 'STOP', 'mediaSessionId': _mediaSessionId});
      } on Exception {
        // 媒体会话可能已自行结束：继续关应用会话。
      }
      _mediaSessionId = null;
    }
    if (_appSessionId != null) {
      try {
        await _requestReceiverStatus(
          {'type': 'STOP', 'requestId': _nextId(), 'sessionId': _appSessionId},
        );
      } on Exception {
        // 接收器会话已死不视为错误。
      }
      _appSessionId = null;
      _transportId = null;
    }
  }

  @override
  Future<void> seekTo(Duration position) async {
    await _mediaCommand({
      'type': 'SEEK',
      'mediaSessionId': _mediaSessionId,
      'currentTime': position.inMilliseconds / 1000.0,
      'resumeState': 'PLAYBACK_START',
    });
  }

  @override
  Future<void> setVolume(int percent) async {
    await _ensureConnected();
    await _requestReceiverStatus({
      'type': 'SET_VOLUME',
      'requestId': _nextId(),
      'volume': {'level': (percent.clamp(0, 100)) / 100.0},
    });
  }

  @override
  Future<CastPoll> poll() async {
    // 未 launch（未投/已 STOP）：无媒体会话可言，不向设备发 media 消息
    // （发到 receiver-0 会被静默丢弃并白白等超时），也不重新 LAUNCH
    // （电视端按停止后不应被自动唤醒）。
    if (!_connected || _transportId == null) {
      return const CastPoll(transportState: 'STOPPED');
    }
    final status = await _requestMediaStatus({
      'type': 'GET_STATUS',
      'requestId': _nextId(),
    });
    final mediaSessionId = status['mediaSessionId'];
    if (mediaSessionId == null) {
      return const CastPoll(transportState: 'STOPPED');
    }
    final playerState = status['playerState'] as String? ?? 'IDLE';
    final media = status['media'];
    final duration =
        media is Map<String, dynamic> ? (media['duration'] as num?) ?? 0 : 0;
    return CastPoll(
      // 状态映射进 CastPoll 词汇表：BUFFERING 不算 running（进度插值暂停）。
      transportState: switch (playerState) {
        'PLAYING' => 'PLAYING',
        'BUFFERING' || 'LOADING' => 'BUFFERING',
        'PAUSED' => 'PAUSED_PLAYBACK',
        _ => 'STOPPED',
      },
      position: Duration(
        milliseconds: (((status['currentTime'] as num?) ?? 0) * 1000).round(),
      ),
      duration: Duration(milliseconds: (duration * 1000).round()),
    );
  }

  @override
  void close() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _messageSub?.cancel();
    _messageSub = null;
    _connected = false;
    _transportId = null;
    _appSessionId = null;
    _mediaSessionId = null;
    _failAllWaiters('通道已关闭');
    _channel.close();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  int _nextId() => ++_requestId;

  void _send(String namespace, String destinationId, Map<String, dynamic> payload) {
    _channel.sendMessage(
      namespace: namespace,
      sourceId: _senderId,
      destinationId: destinationId,
      payload: jsonEncode(payload),
    );
  }

  void _safeSend(String namespace, String destinationId, Map<String, dynamic> payload) {
    try {
      _send(namespace, destinationId, payload);
    } catch (_) {
      // 心跳失败留给轮询超时处理。
    }
  }

  void _onMessage(CastMessage message) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(message.payloadUtf8) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = json['type'] as String?;
    final requestId = json['requestId'] as int?;
    switch (message.namespace_) {
      case _nsMedia:
        if (type == 'MEDIA_STATUS') {
          final status = (json['status'] as List?)?.firstOrNull;
          if (status is Map<String, dynamic>) {
            final waiter =
                requestId == null ? null : _mediaStatusWaiters.remove(requestId);
            waiter?.complete(status);
          } else if (requestId != null) {
            // 无会话状态（停止后 GET_STATUS / LOAD 失败）。
            _mediaStatusWaiters.remove(requestId)?.complete(<String, dynamic>{});
          }
        }
      case _nsReceiver:
        if (type == 'RECEIVER_STATUS' && requestId != null) {
          _receiverStatusWaiters.remove(requestId)?.complete(json);
        }
      default:
        if (type != null &&
            (type.endsWith('ERROR') || _errorTypes.contains(type))) {
          final waiter = requestId == null
              ? null
              : (_mediaStatusWaiters.remove(requestId) ??
                  _receiverStatusWaiters.remove(requestId));
          waiter?.completeError(CastException('Chromecast 拒绝请求（$type）'));
        }
    }
  }

  Future<Map<String, dynamic>> _requestReceiverStatus(
    Map<String, dynamic> payload,
  ) {
    final id = payload['requestId'] as int;
    final completer = _receiverStatusWaiters.putIfAbsent(id, Completer.new);
    _send(_nsReceiver, _receiverId, payload);
    return completer.future.timeout(readyTimeout, onTimeout: () {
      _receiverStatusWaiters.remove(id);
      throw CastException('Chromecast 无响应（RECEIVER_STATUS 超时）');
    });
  }

  Future<Map<String, dynamic>> _requestMediaStatus(
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) {
    final id = payload['requestId'] as int;
    final completer = _mediaStatusWaiters.putIfAbsent(id, Completer.new);
    _send(_nsMedia, _transportId ?? _receiverId, payload);
    return completer.future.timeout(timeout ?? const Duration(seconds: 4),
        onTimeout: () {
      _mediaStatusWaiters.remove(id);
      throw CastException('Chromecast 无响应（MEDIA_STATUS 超时）');
    });
  }

  Future<void> _mediaCommand(Map<String, dynamic> payload) async {
    await _ensureConnected();
    if (_transportId == null) {
      await _ensureLaunched();
    }
    payload['requestId'] = _nextId();
    await _requestMediaStatus(payload);
  }

  static String _guessMime(Uri url) {
    final path = url.path.toLowerCase();
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) {
      return 'application/x-mpegurl';
    }
    if (path.endsWith('.webm')) return 'video/webm';
    if (path.endsWith('.mkv')) return 'video/x-matroska';
    return 'video/mp4';
  }

  void _failAllWaiters(String reason) {
    for (final w in _mediaStatusWaiters.values) {
      if (!w.isCompleted) w.completeError(CastException(reason));
    }
    _mediaStatusWaiters.clear();
    for (final w in _receiverStatusWaiters.values) {
      if (!w.isCompleted) w.completeError(CastException(reason));
    }
    _receiverStatusWaiters.clear();
  }
}
