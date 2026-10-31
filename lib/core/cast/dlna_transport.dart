import 'cast_controller.dart';
import 'dlna_device.dart';
import 'soap_client.dart';

/// DLNA SOAP 传输实现（AVTransport 控制 + RenderingControl 音量）。
///
/// 自 cast_controller.dart 迁出（P0 多协议改造），行为契约不变。
class DlnaTransport implements CastTransport {
  DlnaTransport(this.device, {SoapClient? client})
      : _client = client ?? SoapClient();

  final DlnaDevice device;
  final SoapClient _client;

  static const _avt = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _rcs = 'urn:schemas-upnp-org:service:RenderingControl:1';

  @override
  Future<void> setUri(
    Uri url, {
    required String title,
    String? duration,
    Uri? subtitleUrl,
  }) async {
    final metadata =
        buildDidlLite(title: title, duration: duration, subtitleUrl: subtitleUrl);
    final args = <String, String>{
      'InstanceID': '0',
      'CurrentURI': url.toString(),
      'CurrentURIMetaData': metadata,
    };
    try {
      await _client.sendAction(device.controlUrl, _avt, 'SetAVTransportURI', args);
    } on SoapException catch (e) {
      // 设备拒绝 metadata（DIDL 校验严格的盒子会报 SOAP fault）：去掉 metadata 重试。
      // 只对「设备返回 fault」重试——超时不重试（SoapClient 已有一层 504 重试，
      // 再叠会把 4s 超时拖成 12s）。
      if (e.faultCode == null) rethrow;
      await _client.sendAction(device.controlUrl, _avt, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url.toString(),
        'CurrentURIMetaData': '',
      });
    }
  }

  @override
  Future<void> play() => _client.sendAction(device.controlUrl, _avt, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });

  @override
  Future<void> pause() => _client.sendAction(device.controlUrl, _avt, 'Pause', {
        'InstanceID': '0',
      });

  @override
  Future<void> stop() => _client.sendAction(device.controlUrl, _avt, 'Stop', {
        'InstanceID': '0',
      });

  @override
  Future<void> seekTo(Duration position) =>
      _client.sendAction(device.controlUrl, _avt, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': formatUpnpTime(position),
      });

  @override
  Future<void> setVolume(int percent) async {
    if (device.renderingControlUrl.isEmpty) {
      throw SoapException('设备不支持音量控制');
    }
    await _client
        .sendAction(device.renderingControlUrl, _rcs, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '$percent',
    });
  }

  @override
  Future<void> setMute(bool muted) async {
    if (device.renderingControlUrl.isEmpty) {
      throw SoapException('设备不支持静音控制');
    }
    await _client
        .sendAction(device.renderingControlUrl, _rcs, 'SetMute', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredMute': muted ? '1' : '0',
    });
  }

  /// 并发取状态与进度：任一路失败不拖累另一路。
  ///
  /// 串行发两个 SOAP 时，一个慢设备就能把 1s 轮询拖成 3s，
  /// 表现是进度条卡住、遥控器暂停要好几秒才反映。
  @override
  Future<CastPoll> poll() async {
    Future<Map<String, String>?> safe(Future<Map<String, String>> call) async {
      try {
        return await call;
      } on SoapException {
        return null;
      }
    }

    final both = await Future.wait<Map<String, String>?>([
      safe(_client.sendAction(device.controlUrl, _avt, 'GetTransportInfo', {
        'InstanceID': '0',
      })),
      safe(_client.sendAction(device.controlUrl, _avt, 'GetPositionInfo', {
        'InstanceID': '0',
      })),
    ]);
    final info = both[0];
    if (info == null) {
      throw SoapException('GetTransportInfo 失败');
    }
    final pos = both[1];
    return CastPoll(
      transportState: info['CurrentTransportState'] ?? '',
      position: parseUpnpTime(pos?['RelTime'] ?? '') ?? Duration.zero,
      duration: parseUpnpTime(pos?['TrackDuration'] ?? '') ?? Duration.zero,
    );
  }

  @override
  void close() => _client.close();
}
