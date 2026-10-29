import 'package:xml/xml.dart';

/// DLNA 设备模型与描述 XML 解析。
///
/// 描述文档语义（UPnP Device Architecture 1.0）：
/// `LOCATION` 指向设备描述 XML；`URLBase`（可选）是相对地址的解析基址；
/// AVTransport 服务的 `controlURL` 是投屏控制端点——没有 AVTransport 的
/// 设备不是投屏目标（如打印机/灯泡也会响应 SSDP）。
class DlnaDevice {
  DlnaDevice({
    required this.udn,
    required this.friendlyName,
    this.modelName = '',
    required this.controlUrl,
    this.renderingControlUrl = '',
    this.location = '',
    DateTime? discoveredAt,
    this.online = true,
  }) : discoveredAt = discoveredAt ?? DateTime.now();

  final String udn;
  final String friendlyName;
  final String modelName;

  /// AVTransport controlURL（绝对地址）。
  final String controlUrl;
  final String renderingControlUrl;
  final String location;
  DateTime discoveredAt;
  bool online;

  Map<String, dynamic> toPersistJson() => {
        'udn': udn,
        'name': friendlyName,
        'model': modelName,
        'control_url': controlUrl,
        'rendering_control_url': renderingControlUrl,
        'location': location,
      };

  factory DlnaDevice.fromPersistJson(Map<String, dynamic> json) => DlnaDevice(
        udn: json['udn'] as String? ?? '',
        friendlyName: json['name'] as String? ?? '',
        modelName: json['model'] as String? ?? '',
        controlUrl: json['control_url'] as String? ?? '',
        renderingControlUrl: json['rendering_control_url'] as String? ?? '',
        location: json['location'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.udn == udn && other.udn.isNotEmpty;

  @override
  int get hashCode => udn.hashCode;

  @override
  String toString() => 'DlnaDevice($friendlyName, $controlUrl)';
}

/// 解析设备描述 XML；没有 AVTransport 服务时返回 null（非投屏目标）。
DlnaDevice? parseDeviceDescription(String xmlText, String location) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } catch (_) {
    return null;
  }
  String? textOf(XmlElement parent, String localName) {
    for (final e in parent.descendantElements) {
      if (e.name.local == localName) {
        return e.innerText.trim();
      }
    }
    return null;
  }

  final root = doc.rootElement;
  // root 可能带命名空间前缀（device/Device）；按 localName 找第一个 device。
  XmlElement? device;
  for (final e in root.descendantElements) {
    if (e.name.local == 'device') {
      device = e;
      break;
    }
  }
  if (device == null) return null;

  // URLBase：描述内相对地址的基址；缺省用 LOCATION 本身。
  final urlBase = textOf(doc.rootElement, 'URLBase');
  final baseUri = Uri.tryParse(urlBase != null && urlBase.isNotEmpty ? urlBase : location) ??
      Uri.parse(location);
  Uri resolve(String ref) {
    final uri = Uri.tryParse(ref);
    if (uri == null) return baseUri;
    if (uri.hasScheme && uri.host.isNotEmpty) return uri;
    try {
      return baseUri.resolve(ref);
    } catch (_) {
      return uri;
    }
  }

  String? avtControl;
  String? rcsControl;
  for (final service in device.descendantElements) {
    if (service.name.local != 'service') continue;
    final serviceType = textOf(service, 'serviceType') ?? '';
    final controlUrl = textOf(service, 'controlURL');
    if (controlUrl == null || controlUrl.isEmpty) continue;
    if (serviceType.contains('AVTransport')) {
      avtControl ??= resolve(controlUrl).toString();
    } else if (serviceType.contains('RenderingControl')) {
      rcsControl ??= resolve(controlUrl).toString();
    }
  }
  if (avtControl == null) return null;

  final udn = textOf(device, 'UDN') ?? '';
  return DlnaDevice(
    udn: udn.isEmpty ? location : udn,
    friendlyName: textOf(device, 'friendlyName') ?? '未命名设备',
    modelName: textOf(device, 'modelName') ?? '',
    controlUrl: avtControl,
    renderingControlUrl: rcsControl ?? '',
    location: location,
  );
}

/// DIDL-Lite 元数据（SetAVTransportURI 的 CurrentURIMetadataData）。
/// 部分盒子校验非空才收，统一带最小 DIDL。
String buildDidlLite({
  required String title,
  String? duration,
  String itemClass = 'object.item.videoItem',
}) {
  final escaped = _escapeXml(title);
  final resAttrs = duration != null && duration.isNotEmpty
      ? ' duration="${_escapeXml(duration)}"'
      : '';
  return '''
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
  <item id="aquan-1" parentID="0" restricted="1">
    <dc:title>$escaped</dc:title>
    <upnp:class>$itemClass</upnp:class>
    <res$resAttrs></res>
  </item>
</DIDL-Lite>''';
}

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
