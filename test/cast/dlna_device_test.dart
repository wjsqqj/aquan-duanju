import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/dlna_device.dart';

void main() {
  group('parseDeviceDescription', () {
    const description = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://192.168.1.23:49152</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅电视</friendlyName>
    <modelName>MI TV 3</modelName>
    <UDN>uuid:abcd-1234</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/dev/abcd-1234/ctrl/AVT</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/dev/abcd-1234/ctrl/RCS</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/dev/abcd-1234/ctrl/CM</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

    test('解析设备信息 + 相对 controlURL 按 URLBase 还原', () {
      final device =
          parseDeviceDescription(description, 'http://192.168.1.23:49152/desc.xml');
      expect(device, isNotNull);
      expect(device!.friendlyName, '客厅电视');
      expect(device.modelName, 'MI TV 3');
      expect(device.udn, 'uuid:abcd-1234');
      expect(device.controlUrl, 'http://192.168.1.23:49152/dev/abcd-1234/ctrl/AVT');
      expect(device.renderingControlUrl,
          'http://192.168.1.23:49152/dev/abcd-1234/ctrl/RCS');
    });

    test('无 URLBase 时按 LOCATION 还原相对路径', () {
      final withoutBase = description.replaceFirst(
          '<URLBase>http://192.168.1.23:49152</URLBase>', '');
      final device = parseDeviceDescription(
          withoutBase, 'http://192.168.1.23:49152/desc.xml');
      expect(device!.controlUrl,
          'http://192.168.1.23:49152/dev/abcd-1234/ctrl/AVT');
    });

    test('没有 AVTransport 服务 → null（非投屏目标）', () {
      final noAvt = description.replaceFirst(
          RegExp(r'<service>.*?AVTransport.*?</service>', dotAll: true), '');
      expect(parseDeviceDescription(noAvt, 'http://x/desc.xml'), isNull);
    });

    test('非法 XML → null', () {
      expect(parseDeviceDescription('<不是xml', 'http://x/'), isNull);
    });
  });

  group('buildDidlLite', () {
    test('标题转义 + 可选时长', () {
      final didl = buildDidlLite(title: '剧名 · <第3集> "特别版"');
      expect(didl, contains('&lt;第3集&gt;'));
      expect(didl, contains('&quot;特别版&quot;'));
      expect(didl, isNot(contains('duration=')));

      final withDuration =
          buildDidlLite(title: 'x', duration: '0:02:15.000');
      expect(withDuration, contains('duration="0:02:15.000"'));
      expect(withDuration, contains('object.item.videoItem'));
    });
  });
}
