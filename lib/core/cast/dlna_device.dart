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
    this.eventSubUrl = '',
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

  /// AVTransport 事件订阅地址（GENA）；空 = 不支持，纯轮询。
  final String eventSubUrl;
  final String location;
  DateTime discoveredAt;
  bool online;

  Map<String, dynamic> toPersistJson() => {
        'udn': udn,
        'name': friendlyName,
        'model': modelName,
        'control_url': controlUrl,
        'rendering_control_url': renderingControlUrl,
        'event_sub_url': eventSubUrl,
        'location': location,
      };

  factory DlnaDevice.fromPersistJson(Map<String, dynamic> json) => DlnaDevice(
        udn: json['udn'] as String? ?? '',
        friendlyName: json['name'] as String? ?? '',
        modelName: json['model'] as String? ?? '',
        controlUrl: json['control_url'] as String? ?? '',
        renderingControlUrl: json['rendering_control_url'] as String? ?? '',
        eventSubUrl: json['event_sub_url'] as String? ?? '',
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

/// 设备描述里 `controlURL` 缺失时的惯例路径（按命中率排序）。
const List<String> kAvtControlFallbacks = <String>[
  '/AVTransport/control',
  '/upnp/control/AVTransport',
  '/control/AVTransport',
];

final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _hasLetter = RegExp(r'[A-Za-z]');

/// 把设备给的 `controlURL` 修成「本机连得上」的地址。
///
/// 国产电视/盒子的描述文件经常写错：
/// - 写成 `http://localhost:8080/...` 或 `127.0.0.1`（设备视角的本机）；
/// - 写成内网域名（DNS 解析不了，但同网段 IP 能通）；
/// - 干脆不写 `controlURL`，只在 `serviceType` 里声明了服务。
///
/// 兜底策略：host 一律取 `LOCATION` 的 host；端口优先用 `controlURL` 自己的，
/// 没写就继承 `LOCATION`；路径为空时按惯例路径猜。
Uri? rebuildControlUrl({
  required String controlUrl,
  required String location,
  List<String> fallbackPaths = kAvtControlFallbacks,
}) {
  final loc = Uri.tryParse(location);
  if (loc == null || loc.host.isEmpty) {
    final raw = Uri.tryParse(controlUrl);
    return raw != null && raw.host.isNotEmpty ? raw : null;
  }

  final ctrl = Uri.tryParse(controlUrl);
  final locIsIp = _ipv4.hasMatch(loc.host);

  var path = ctrl?.path ?? '';
  var query = ctrl?.query ?? '';
  var scheme = ctrl != null && ctrl.scheme.isNotEmpty ? ctrl.scheme : loc.scheme;

  // 决定 host：设备自指地址一律换掉；域名 + LOCATION 是 IP 时也换（局域网 DNS 通常不通）。
  var host = loc.host;
  if (ctrl != null && ctrl.host.isNotEmpty) {
    final selfRef = ctrl.host == 'localhost' ||
        ctrl.host == '127.0.0.1' ||
        ctrl.host == '0.0.0.0' ||
        ctrl.host == '[::1]';
    final domainButIpKnown = locIsIp && _hasLetter.hasMatch(ctrl.host);
    if (!selfRef && !domainButIpKnown) host = ctrl.host;
  }

  // 端口：优先 controlURL 自己的（部分设备控制端口与描述端口不同），没写才继承 LOCATION。
  int? port = ctrl != null && ctrl.hasPort ? ctrl.port : null;
  port ??= loc.hasPort ? loc.port : null;

  if (path.isEmpty || path == '/') {
    path = fallbackPaths.isEmpty ? '/AVTransport/control' : fallbackPaths.first;
    query = '';
  }
  if (scheme.isEmpty) scheme = 'http';

  return Uri(
    scheme: scheme,
    host: host,
    port: port,
    path: path,
    query: query.isEmpty ? null : query,
  );
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
  String? avtEventSub;
  for (final service in device.descendantElements) {
    if (service.name.local != 'service') continue;
    final serviceType = textOf(service, 'serviceType') ?? '';
    final isAvt = serviceType.contains('AVTransport');
    final isRcs = serviceType.contains('RenderingControl');
    if (!isAvt && !isRcs) continue;
    final rawControl = textOf(service, 'controlURL') ?? '';
    // 先按 URLBase/LOCATION 解析相对地址，再按「设备自指 / 域名 vs IP」兜底重建。
    final resolved = rawControl.isEmpty
        ? location
        : resolve(rawControl).toString();
    final rebuilt = rebuildControlUrl(
      controlUrl: rawControl.isEmpty ? '' : resolved,
      location: location,
    );
    if (rebuilt == null) continue;
    if (isAvt) {
      avtControl ??= rebuilt.toString();
      final rawEvent = textOf(service, 'eventSubURL') ?? '';
      if (rawEvent.isNotEmpty) {
        avtEventSub ??=
            rebuildControlUrl(controlUrl: resolve(rawEvent).toString(), location: location)
                ?.toString();
      }
    } else {
      rcsControl ??= rebuilt.toString();
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
    eventSubUrl: avtEventSub ?? '',
    location: location,
  );
}

/// DIDL-Lite 元数据（SetAVTransportURI 的 CurrentURIMetadataData）。
/// 部分盒子校验非空才收，统一带最小 DIDL。
/// [subtitleUrl] 非空时带 `sec:SubtitleUri`（三星扩展，多数国产电视兼容外挂字幕投送）。
String buildDidlLite({
  required String title,
  String? duration,
  String itemClass = 'object.item.videoItem',
  Uri? subtitleUrl,
}) {
  final escaped = _escapeXml(title);
  final resAttrs = duration != null && duration.isNotEmpty
      ? ' duration="${_escapeXml(duration)}"'
      : '';
  final subtitle = subtitleUrl == null
      ? ''
      : '\n    <sec:SubtitleUri>${_escapeXml(subtitleUrl.toString())}</sec:SubtitleUri>';
  return '''
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
           xmlns:sec="http://www.sec.co.kr/">
  <item id="aquan-1" parentID="0" restricted="1">
    <dc:title>$escaped</dc:title>
    <upnp:class>$itemClass</upnp:class>
    <res$resAttrs></res>$subtitle
  </item>
</DIDL-Lite>''';
}

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
