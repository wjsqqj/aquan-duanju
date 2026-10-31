import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/mdns_discovery.dart';

void main() {
  group('mDNS 发现（纯函数层）', () {
    test('parseTxt：换行连接的 key=value 解析', () {
      final txt = MdnsDiscovery.parseTxt('fn=客厅电视\nid=abc123\nmd=Google TV\n\n');
      expect(txt['fn'], '客厅电视');
      expect(txt['id'], 'abc123');
      expect(txt['md'], 'Google TV');
      expect(txt, hasLength(3));
    });

    test('parseTxt：无 = 的行忽略', () {
      final txt = MdnsDiscovery.parseTxt('notapair\nfn=x');
      expect(txt, {'fn': 'x'});
    });

    test('stripServiceSuffix：服务名去后缀', () {
      expect(MdnsDiscovery.stripServiceSuffix('客厅电视._googlecast._tcp.local'),
          '客厅电视');
      expect(MdnsDiscovery.stripServiceSuffix('NoSuffix'), 'NoSuffix');
    });

    test('discover 尊重 clientOverride：空 PTR → 立即结束', () async {
      // 注入假 client：lookup 返回空流 → discover 立即完成且不抛错。
      final devices = await MdnsDiscovery.discover(
        MdnsDiscovery.chromecastServiceType,
        clientOverride: _FakeMdnsClient(),
        rounds: 1,
      ).toList();
      expect(devices, isEmpty);
    });
  });

  group('CastDeviceInfo → CastTarget', () {
    test('id 稳定：host:port', () {
      const info = CastDeviceInfo(host: '192.168.1.50', port: 8009, name: '谷歌电视');
      final t = CastTarget.chromecast(info);
      expect(t.id, 'cast:192.168.1.50:8009');
      expect(t.protocol, CastProtocol.chromecast);
      expect(t.name, '谷歌电视');
      // 同 host:port 再次发现 → upsert 语义下等价。
      expect(CastTarget.chromecast(info), t);
    });

    test('name 为空时回退 host', () {
      final t = CastTarget.chromecast(const CastDeviceInfo(host: '10.0.0.3'));
      expect(t.name, '10.0.0.3');
    });
  });
}

/// 空 mDNS 客户端：lookup 直接给空流。
class _FakeMdnsClient implements MDnsClient {
  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {}

  @override
  Stream<T> lookup<T extends ResourceRecord>(ResourceRecordQuery query,
          {Duration timeout = const Duration(seconds: 5)}) =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
