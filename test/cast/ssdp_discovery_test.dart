import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/ssdp_discovery.dart';

void main() {
  group('buildSearchPacket', () {
    test('M-SEARCH 报文格式（CineFlow 同款）', () {
      final packet = buildSearchPacket('urn:schemas-upnp-org:device:MediaRenderer:1');
      expect(packet.startsWith('M-SEARCH * HTTP/1.1\r\n'), isTrue);
      expect(packet, contains('HOST: 239.255.255.250:1900'));
      expect(packet, contains('MAN: "ssdp:discover"'));
      expect(packet, contains('MX: 2'));
      expect(packet, contains('ST: urn:schemas-upnp-org:device:MediaRenderer:1'));
      expect(packet.endsWith('\r\n\r\n'), isTrue);
    });
  });

  group('parseSsdpHeaders', () {
    test('M-SEARCH 响应（大小写混合键 → 统一大写键）', () {
      const text = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'EXT:\r\n'
          'location: http://192.168.1.23:49152/description.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:abc::urn:1\r\n'
          '\r\n';
      final headers = parseSsdpHeaders(text);
      expect(headers, isNotNull);
      expect(headers!['LOCATION'], 'http://192.168.1.23:49152/description.xml');
      expect(headers['USN'], 'uuid:abc::urn:1');
    });

    test('NOTIFY alive / byebye', () {
      const alive = 'NOTIFY * HTTP/1.1\r\nNTS: ssdp:alive\r\n'
          'LOCATION: http://x/desc.xml\r\nUSN: uuid:1\r\n\r\n';
      const byebye = 'NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: uuid:1\r\n\r\n';
      expect(parseSsdpHeaders(alive)!['NTS'], 'ssdp:alive');
      expect(parseSsdpHeaders(byebye)!['NTS'], 'ssdp:byebye');
    });

    test('非 SSDP 报文 → null', () {
      expect(parseSsdpHeaders('random udp garbage'), isNull);
    });
  });
}
