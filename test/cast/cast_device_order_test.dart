import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_service.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';

CastTarget _dlna(
  String udn,
  String name, {
  String host = '192.168.1.8',
  String model = 'Hisilicon MediaRenderer',
  bool online = true,
}) =>
    CastTarget.dlna(DlnaDevice(
      udn: udn,
      friendlyName: name,
      modelName: model,
      controlUrl: 'http://$host:49152/ctrl',
      online: online,
    ));

List<String> _ids(List<CastTarget> list) => [for (final d in list) d.id];

void main() {
  final sort = CastService.instance.sortDevices;

  group('设备排序全序化（11-09 用户反馈）', () {
    // 真机现场的形态：两台同名「央视频电视投屏助手」、两台同名「投屏电视Q3」。
    final devices = <CastTarget>[
      _dlna('uuid:cctv-242', '央视频电视投屏助手', host: '192.168.31.242'),
      _dlna('uuid:cctv-159', '央视频电视投屏助手', host: '192.168.31.159'),
      _dlna('uuid:q3-242', '投屏电视Q3', host: '192.168.31.242'),
      _dlna('uuid:q3-159', '投屏电视Q3', host: '192.168.31.159'),
      _dlna('uuid:airpin', 'wjsqqj', host: '192.168.31.159'),
      CastTarget.chromecast(
          const CastDeviceInfo(host: '192.168.31.9', name: '客厅音箱')),
    ];

    test('同名不同 id：任意输入顺序输出一致（10 次打乱）', () {
      final expected = _ids(sort(devices, pinnedIds: const <String>{}));
      final random = Random(20261109);
      for (var i = 0; i < 10; i++) {
        final shuffled = List<CastTarget>.of(devices)..shuffle(random);
        expect(_ids(sort(shuffled, pinnedIds: const <String>{})), expected,
            reason: '第 $i 次打乱后顺序漂移');
      }
    });

    test('在线状态不参与排序：全部置离线后顺序不变', () {
      final expected = _ids(sort(devices, pinnedIds: const <String>{}));
      for (final d in devices) {
        d.online = false;
      }
      expect(_ids(sort(devices, pinnedIds: const <String>{})), expected);
      // 只影响副标题里的「离线」标记。
      expect(castDeviceSubtitle(devices.first), contains('离线'));
    });

    test('在线/离线混合不影响相对顺序', () {
      final mixed = <CastTarget>[
        _dlna('uuid:a', 'B设备', online: false),
        _dlna('uuid:b', 'A设备'),
        _dlna('uuid:c', 'B设备', online: true),
      ];
      final order = _ids(sort(mixed, pinnedIds: const <String>{}));
      // 同名按 id 兜底：uuid:a 在 uuid:c 之前，与在线状态无关。
      expect(order, <String>['uuid:b', 'uuid:a', 'uuid:c']);
    });

    test('钉选 > 最近使用 > 其它', () {
      final list = <CastTarget>[
        _dlna('uuid:z', 'Z设备'),
        _dlna('uuid:m', 'M设备'),
        _dlna('uuid:a', 'A设备'),
      ];
      final ordered = sort(list,
          pinnedIds: const <String>{'uuid:z'}, lastId: 'uuid:m');
      expect(_ids(ordered), <String>['uuid:z', 'uuid:m', 'uuid:a']);
    });
  });

  group('设备副标题（11-09：恒显示 IP）', () {
    test('协议 · 型号 · IP', () {
      expect(
        castDeviceSubtitle(_dlna('uuid:1', 'TV', host: '192.168.31.159')),
        'DLNA · Hisilicon MediaRenderer · 192.168.31.159',
      );
    });

    test('型号为空时省略该段；离线追加标记', () {
      final target = _dlna('uuid:2', 'TV', host: '192.168.31.8', model: '')
        ..online = false;
      expect(castDeviceSubtitle(target), 'DLNA · 192.168.31.8 · 离线');
    });

    test('AirPlay / Chromecast 协议名', () {
      expect(
        castDeviceSubtitle(CastTarget.airplay(
            const AirPlayDeviceInfo(host: '192.168.31.7', name: 'TV'))),
        'AirPlay · 192.168.31.7',
      );
      expect(
        castDeviceSubtitle(CastTarget.chromecast(
            const CastDeviceInfo(host: '192.168.31.9', name: '音箱'))),
        'Chromecast · 192.168.31.9',
      );
    });
  });

  group('本轮未见标离线（11-09：扫描不再清空列表）', () {
    test('只标 DLNA；不改列表长度与顺序；不动 Chromecast/AirPlay', () {
      final list = <CastTarget>[
        _dlna('uuid:seen', '已见'),
        _dlna('uuid:gone', '未见'),
        CastTarget.chromecast(
            const CastDeviceInfo(host: '192.168.31.9', name: '音箱')),
        CastTarget.airplay(
            const AirPlayDeviceInfo(host: '192.168.31.7', name: 'TV')),
      ];
      final before = _ids(list);
      markStaleDlnaOffline(list, <String>{'uuid:seen'});

      expect(_ids(list), before, reason: '顺序与长度都不变');
      expect(list[0].online, isTrue);
      expect(list[1].online, isFalse, reason: '本轮未见的 DLNA 标离线');
      expect(list[1].dlna!.online, isFalse);
      expect(list[2].online, isTrue, reason: 'Chromecast 无「本轮」概念');
      expect(list[3].online, isTrue, reason: 'AirPlay 无「本轮」概念');
    });

    test('空 seen 集合：所有 DLNA 标离线', () {
      final list = <CastTarget>[_dlna('uuid:1', 'A'), _dlna('uuid:2', 'B')];
      markStaleDlnaOffline(list, <String>{});
      expect(list.every((d) => !d.online), isTrue);
    });
  });
}
