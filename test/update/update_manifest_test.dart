import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/update/update_manifest.dart';

void main() {
  group('UpdateManifest.parse', () {
    test('多平台 assets + sha256 映射', () {
      final manifest = UpdateManifest.parse('''
{
  "version": "1.5.0",
  "versionCode": 20,
  "changelog": "更新内容",
  "assets": {
    "windows": ["https://gh/a/setup.exe", "https://mirror/setup.exe"],
    "android-arm64-v8a": ["https://gh/a/app.apk"]
  },
  "sha256": {
    "windows": "ABCDEF",
    "android-arm64-v8a": "123456"
  }
}
''');
      expect(manifest, isNotNull);
      expect(manifest!.version, '1.5.0');
      expect(manifest.versionCode, 20);
      expect(manifest.assetUrlsFor('windows').length, 2);
      expect(manifest.assetUrlsFor('android-arm64-v8a').single,
          'https://gh/a/app.apk');
      expect(manifest.shaFor('windows'), 'ABCDEF');
      expect(manifest.shaFor('android-armeabi-v7a'), isNull);
    });

    test('兼容 TVBox 顶层 apk 数组与字符串 sha256', () {
      final manifest = UpdateManifest.parse('''
{"versionName":"1.2.3","apk":["https://x/app.apk"],"sha256":"DEADBEEF"}
''');
      expect(manifest, isNotNull);
      expect(manifest!.assetUrlsFor('android-arm64-v8a').single,
          'https://x/app.apk');
      expect(manifest.shaFor('android-x86_64'), 'DEADBEEF');
    });

    test('files 作为 assets 别名', () {
      final manifest = UpdateManifest.parse(
          '{"version":"2.0.0","files":{"windows":"https://x/setup.exe"}}');
      expect(manifest?.assetUrlsFor('windows').single, 'https://x/setup.exe');
    });

    test('缺版本或缺资产返回 null', () {
      expect(UpdateManifest.parse('{"assets":{"windows":["https://x/a"]}}'),
          isNull);
      expect(UpdateManifest.parse('{"version":"1.0.0"}'), isNull);
      expect(UpdateManifest.parse('not json'), isNull);
      // 非 http(s) 资产不算数。
      expect(UpdateManifest.parse('{"version":"1.0.0","apk":["ftp://x/a.apk"]}'),
          isNull);
    });

    test('Android 平台缺精确键时回退同平台资产', () {
      final manifest = UpdateManifest.parse(
          '{"version":"1.0.0","assets":{"android-arm64-v8a":["https://x/a.apk"]}}');
      expect(manifest!.assetUrlsFor('android-x86_64').single,
          'https://x/a.apk');
    });
  });

  group('版本比较', () {
    test('主/次/补丁逐段比较', () {
      expect(UpdateManifest.compareVersions('1.5.0', '1.4.9'), greaterThan(0));
      expect(UpdateManifest.compareVersions('1.4.0+19', '1.4.0'), 0);
      expect(UpdateManifest.compareVersions('1.4.0', '1.4.1'), lessThan(0));
      expect(UpdateManifest.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    });

    test('isNewerThan', () {
      final manifest =
          UpdateManifest.parse('{"version":"1.5.0","apk":["https://x/a"]}')!;
      expect(manifest.isNewerThan('1.4.0'), isTrue);
      expect(manifest.isNewerThan('1.5.0'), isFalse);
    });
  });

  group('versionCode 兜底', () {
    UpdateManifest build({int code = 0}) => UpdateManifest.parse(
          '{"version":"1.5.0","versionCode":$code,"apk":["https://x/a"]}',
        )!;

    test('版本号相等时用构建号判定', () {
      expect(
        build(code: 70).isNewerThanWithCode('1.5.0', currentBaseCode: 69),
        isTrue,
      );
      expect(
        build(code: 69).isNewerThanWithCode('1.5.0', currentBaseCode: 69),
        isFalse,
      );
    });

    test('版本号不等时不看构建号', () {
      // 版本号更旧但构建号更大：不能因此提示「有更新」，避免用户被拉回旧版本。
      expect(
        build(code: 999).isNewerThanWithCode('1.6.0', currentBaseCode: 69),
        isFalse,
      );
      expect(
        build(code: 1).isNewerThanWithCode('1.4.0', currentBaseCode: 69),
        isTrue,
      );
    });

    test('缺构建号时等价于纯语义化比较', () {
      expect(build().isNewerThanWithCode('1.5.0', currentBaseCode: 69), isFalse);
      expect(build().isNewerThanWithCode('1.4.0', currentBaseCode: 69), isTrue);
    });

    test('构建号 ≥1000 时不参与比较（split-abi 偏移已不可还原）', () {
      final manifest = build(code: 1070);
      expect(manifest.versionCodeComparable, isFalse);
      expect(
        manifest.isNewerThanWithCode('1.5.0', currentBaseCode: 70),
        isFalse,
      );
      expect(manifest.isMandatory('1.5.0', currentBaseCode: 70), isFalse);
    });

    test('构建号写成字符串也能解析', () {
      final manifest = UpdateManifest.parse(
        '{"version":"1.5.0","versionCode":"70","apk":["https://x/a"]}',
      )!;
      expect(manifest.versionCode, 70);
      expect(
        manifest.isNewerThanWithCode('1.5.0', currentBaseCode: 69),
        isTrue,
      );
    });
  });

  group('强制更新', () {
    UpdateManifest parse(String extra) => UpdateManifest.parse(
          '{"version":"2.0.0","apk":["https://x/a"]$extra}',
        )!;

    test('force: true 无条件强制', () {
      final manifest = parse(',"force":true');
      expect(manifest.force, isTrue);
      expect(manifest.isMandatory('1.9.0'), isTrue);
    });

    test('低于 minSupportedVersion 强制', () {
      final manifest = parse(',"minSupportedVersion":"1.8.0"');
      expect(manifest.minSupportedVersion, '1.8.0');
      expect(manifest.isMandatory('1.7.9'), isTrue);
      expect(manifest.isMandatory('1.8.0'), isFalse);
      expect(manifest.isMandatory('1.9.0'), isFalse);
    });

    test('构建号落后且版本相同时强制', () {
      final manifest = UpdateManifest.parse(
        '{"version":"2.0.0","versionCode":80,"apk":["https://x/a"]}',
      )!;
      expect(manifest.isMandatory('2.0.0', currentBaseCode: 79), isTrue);
      expect(manifest.isMandatory('2.0.0', currentBaseCode: 80), isFalse);
      // 非 Android（currentBaseCode = 0）不参与。
      expect(manifest.isMandatory('2.0.0'), isFalse);
    });

    test('缺省字段不强制', () {
      final manifest = parse('');
      expect(manifest.force, isFalse);
      expect(manifest.minSupportedVersion, isEmpty);
      expect(manifest.isMandatory('1.0.0'), isFalse);
    });
  });
}
