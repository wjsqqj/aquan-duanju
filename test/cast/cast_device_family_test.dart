import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_device_family.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';

CastTarget targetOf(
  String name, {
  String model = '',
  String manufacturer = '',
}) =>
    CastTarget.dlna(DlnaDevice(
      udn: 'uuid:$name',
      friendlyName: name,
      modelName: model,
      manufacturer: manufacturer,
      controlUrl: 'http://192.168.31.159:49152/ctl',
    ));

void main() {
  group('设备族识别（11-10 真机设备清单）', () {
    test('六族按 modelName 命中', () {
      expect(
        castDeviceFamilyOf(targetOf('我的果果投屏', model: 'Windows Media Player')),
        CastDeviceFamily.wmp,
      );
      expect(
        castDeviceFamilyOf(targetOf('投屏电视Q3', model: 'Windows Media Player')),
        CastDeviceFamily.wmp,
      );
      expect(
        castDeviceFamilyOf(targetOf('wjsqqj', model: 'WaxRainPlayer')),
        CastDeviceFamily.waxrain,
      );
      expect(
        castDeviceFamilyOf(targetOf('TV(192.168.31.159）', model: 'HappyCast')),
        CastDeviceFamily.happycast,
      );
      expect(
        castDeviceFamilyOf(targetOf('客厅极光TV(dlna)', model: 'QQLiveTV Render')),
        CastDeviceFamily.qqlive,
      );
      expect(
        castDeviceFamilyOf(
          targetOf('Living Room 1_3186(HiDMR)', model: 'Hisilicon MediaRenderer'),
          // 海思的 friendlyName 里带 HiDMR。
        ),
        CastDeviceFamily.hisilicon,
      );
      expect(
        castDeviceFamilyOf(
          targetOf('央视频电视投屏助手',
              model: 'LCD-xxDEM6A-B', manufacturer: 'SHARP'),
        ),
        CastDeviceFamily.sharpCling,
      );
    });

    test('大小写不敏感', () {
      expect(
        castDeviceFamilyOf(targetOf('x', model: 'WINDOWS MEDIA PLAYER')),
        CastDeviceFamily.wmp,
      );
      expect(
        castDeviceFamilyOf(targetOf('x', model: 'waxrainplayer')),
        CastDeviceFamily.waxrain,
      );
    });

    test('modelName 缺失时按厂商兜底', () {
      expect(
        castDeviceFamilyOf(targetOf('客厅盒子', manufacturer: 'LEBO')),
        CastDeviceFamily.happycast,
      );
      expect(
        castDeviceFamilyOf(targetOf('x', manufacturer: 'WaxRain')),
        CastDeviceFamily.waxrain,
      );
      expect(
        castDeviceFamilyOf(targetOf('随便一台', manufacturer: 'Unknown')),
        CastDeviceFamily.unknown,
      );
    });

    test('族默认档位：只有 WMP 族要 ts', () {
      expect(relayFormatForFamily(CastDeviceFamily.wmp), 'ts');
      for (final f in CastDeviceFamily.values) {
        if (f == CastDeviceFamily.wmp) continue;
        expect(relayFormatForFamily(f), 'hls', reason: f.name);
      }
    });

    test('标签含族名与来源，便于诊断回传', () {
      expect(castDeviceFamilyLabel(CastDeviceFamily.wmp), contains('wmp'));
      expect(castDeviceFamilyLabel(CastDeviceFamily.qqlive), contains('极光'));
      expect(castDeviceFamilyLabel(CastDeviceFamily.unknown), 'unknown');
    });
  });
}
