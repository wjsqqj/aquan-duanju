import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'proto/cast_channel.dart';

/// 连接工厂（测试注入点：换普通 Socket 连本地假接收器）。
typedef CastSocketFactory = Future<Socket> Function(String host, int port);

/// CASTV2 TLS 通道：连接 Chromecast（8009），4 字节大端长度前缀的 protobuf 帧。
///
/// 移植自 dart_cast（MIT）；socketFactory 为本仓新增（测试注入）。
class CastV2Channel {
  CastV2Channel({CastSocketFactory? socketFactory})
      : _socketFactory = socketFactory ?? _defaultConnect;

  static Future<Socket> _defaultConnect(String host, int port) {
    // Chromecast 自签证书：跳过校验（与 dart_cast/playbridge 一致）。
    return SecureSocket.connect(host, port,
        onBadCertificate: (_) => true, timeout: const Duration(seconds: 5));
  }

  final CastSocketFactory _socketFactory;

  Socket? _socket;
  StreamController<CastMessage>? _messages;
  StreamSubscription<CastMessage>? _sub;

  // ---------------------------------------------------------------------------
  // 帧编解码（静态、可单测）
  // ---------------------------------------------------------------------------

  static Uint8List writeLength(int length) {
    final data = ByteData(4)..setUint32(0, length, Endian.big);
    return data.buffer.asUint8List();
  }

  static int readLength(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint32(0, Endian.big);

  static Uint8List frameMessage(CastMessage message) {
    final protobufBytes = message.writeToBuffer();
    final header = writeLength(protobufBytes.length);
    final frame = Uint8List(4 + protobufBytes.length);
    frame.setRange(0, 4, header);
    frame.setRange(4, frame.length, protobufBytes);
    return frame;
  }

  /// 字节流 → CastMessage 流（缓冲半包，凑齐「4 字节头 + N 字节体」才出一条）。
  static Stream<CastMessage> parseMessages(Stream<List<int>> source) async* {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in source) {
      buffer.add(chunk);
      while (true) {
        final accumulated = buffer.takeBytes();
        if (accumulated.length < 4) {
          buffer.add(accumulated);
          break;
        }
        final messageLength =
            readLength(Uint8List.sublistView(accumulated, 0, 4));
        if (accumulated.length < 4 + messageLength) {
          buffer.add(accumulated);
          break;
        }
        final messageBytes =
            Uint8List.sublistView(accumulated, 4, 4 + messageLength);
        yield CastMessage.fromBuffer(messageBytes);
        final remaining =
            Uint8List.sublistView(accumulated, 4 + messageLength);
        if (remaining.isNotEmpty) {
          buffer.add(remaining);
        } else {
          break;
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 连接生命周期
  // ---------------------------------------------------------------------------

  Future<void> connect(String host, {int port = 8009}) async {
    _socket = await _socketFactory(host, port);
    _messages = StreamController<CastMessage>.broadcast();
    _sub = parseMessages(_socket!).listen(
      _messages!.add,
      onError: _messages!.addError,
      onDone: () => _messages?.close(),
    );
  }

  Stream<CastMessage> get messageStream {
    final messages = _messages;
    if (messages == null) {
      throw StateError('Not connected. Call connect() first.');
    }
    return messages.stream;
  }

  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Not connected. Call connect() first.');
    }
    final message = CastMessage()
      ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
      ..sourceId = sourceId
      ..destinationId = destinationId
      ..namespace_ = namespace
      ..payloadType = CastMessage_PayloadType.STRING
      ..payloadUtf8 = payload;
    socket.add(frameMessage(message));
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
    await _messages?.close();
    _messages = null;
  }
}
