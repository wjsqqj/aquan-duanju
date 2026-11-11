import 'dart:convert';

import 'package:aquan_duanju/update/update_errors.dart';
import 'package:aquan_duanju/update/update_manifest.dart';
import 'package:aquan_duanju/update/update_mirror_probe.dart';
import 'package:aquan_duanju/update/update_mirrors.dart';
import 'package:aquan_duanju/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

UpdateMirror _mirror(String id) =>
    UpdateMirror(id: id, label: id, prefix: 'https://$id/');

List<String> _ids(List<UpdateMirror> mirrors) =>
    [for (final mirror in mirrors) mirror.id];

void main() {
  group('isSkippedVersion', () {
    test('未设置跳过时不跳过任何版本', () {
      expect(UpdateService.isSkippedVersion('1.5.0', ''), isFalse);
    });

    test('跳过的版本及其更旧版本视为跳过', () {
      expect(UpdateService.isSkippedVersion('1.5.0', '1.5.0'), isTrue);
      expect(UpdateService.isSkippedVersion('1.4.9', '1.5.0'), isTrue);
    });

    test('出现更新的版本后自动失效', () {
      expect(UpdateService.isSkippedVersion('1.5.1', '1.5.0'), isFalse);
      expect(UpdateService.isSkippedVersion('1.6.0', '1.5.0'), isFalse);
    });
  });

  group('downloadFailureKind', () {
    test('有过校验失败归为校验失败', () {
      expect(
        UpdateService.downloadFailureKind(1),
        UpdateFailureKind.checksumMismatch,
      );
    });

    test('纯网络失败归为网络', () {
      expect(UpdateService.downloadFailureKind(0), UpdateFailureKind.network);
    });
  });

  group('orderByProbe', () {
    final mirrors = [_mirror('a'), _mirror('b'), _mirror('c')];

    test('探测结果为空时保持原顺序', () {
      expect(
        _ids(UpdateService.orderByProbe(mirrors, null, (m) => m.id)),
        <String>['a', 'b', 'c'],
      );
      expect(
        _ids(UpdateService.orderByProbe(
          mirrors,
          MirrorProbeResult.empty,
          (m) => m.id,
        )),
        <String>['a', 'b', 'c'],
      );
    });

    test('可达的按延迟排序，未探测到的保留在最后（只排序不丢弃）', () {
      const probe = MirrorProbeResult(reachableIds: ['c', 'a']);
      expect(
        _ids(UpdateService.orderByProbe(mirrors, probe, (m) => m.id)),
        <String>['c', 'a', 'b'],
      );
    });

    test('探测结果里全是未知 id 时不丢镜像', () {
      const probe = MirrorProbeResult(reachableIds: ['x', 'y']);
      expect(
        _ids(UpdateService.orderByProbe(mirrors, probe, (m) => m.id)),
        <String>['a', 'b', 'c'],
      );
    });
  });

  group('baseCodeFromBuildNumber', () {
    test('split-per-abi 的 1000 偏移可还原', () {
      expect(UpdateService.baseCodeFromBuildNumber('2070'), 70);
      expect(UpdateService.baseCodeFromBuildNumber('1070'), 70);
    });

    test('未偏移的构建号原样返回', () {
      expect(UpdateService.baseCodeFromBuildNumber('70'), 70);
      expect(UpdateService.baseCodeFromBuildNumber(' 999 '), 999);
    });

    test('无法还原或非法输入返回 0（禁用兜底）', () {
      expect(UpdateService.baseCodeFromBuildNumber('2000'), 0);
      expect(UpdateService.baseCodeFromBuildNumber('abc'), 0);
      expect(UpdateService.baseCodeFromBuildNumber(''), 0);
      expect(UpdateService.baseCodeFromBuildNumber('-1'), 0);
    });
  });

  group('isTrustedAssetUrl', () {
    test('接受本仓库 Release 地址（大小写不敏感）', () {
      expect(
        UpdateService.isTrustedAssetUrl(
          'https://github.com/wjsqqj/aquan-duanju/releases/download/v1.11.7/'
          'aquan-windows-x64-1.11.7-setup.exe',
        ),
        isTrue,
      );
      expect(
        UpdateService.isTrustedAssetUrl(
          'https://github.com/WJSQQJ/Aquan-Duanju/releases/download/v1/x.exe',
        ),
        isTrue,
      );
    });

    test('拒绝其它仓库 / 其它域名 / 非 https', () {
      for (final url in <String>[
        'https://github.com/other/repo/releases/download/v1/x.exe',
        'https://evil.example.com/wjsqqj/aquan-duanju/releases/x.exe',
        'http://github.com/wjsqqj/aquan-duanju/releases/download/v1/x.exe',
        // 相似前缀的仓库名不能被误判成本仓库。
        'https://github.com/wjsqqj/aquan-duanju-other/releases/x.exe',
        'https://github.com/wjsqqj/aquan-duanju/raw/main/x.exe',
        'not-a-url',
      ]) {
        expect(
          UpdateService.isTrustedAssetUrl(url),
          isFalse,
          reason: url,
        );
      }
    });
  });

  group('UpdateManifest.toJson 往返', () {
    test('离线缓存序列化后能原样解析回来', () {
      final original = UpdateManifest.parse(
        '{"version":"1.12.0","versionCode":72,"force":true,'
        '"minSupportedVersion":"1.10.0","changelog":"改了点什么",'
        '"assets":{"windows":["https://github.com/wjsqqj/aquan-duanju/releases/download/v1.12.0/x.exe"]},'
        '"sha256":{"windows":"ABCDEF"}}',
      )!;
      final restored =
          UpdateManifest.parse(jsonEncode(original.toJson()))!;
      expect(restored.version, original.version);
      expect(restored.versionCode, original.versionCode);
      expect(restored.changelog, original.changelog);
      expect(restored.force, original.force);
      expect(restored.minSupportedVersion, original.minSupportedVersion);
      expect(restored.assetUrlsFor('windows'), original.assetUrlsFor('windows'));
      expect(restored.shaFor('windows'), original.shaFor('windows'));
    });
  });

  group('失败文案', () {
    test('每种失败都有非空且互不相同的文案', () {
      final messages = <String>{};
      for (final kind in UpdateFailureKind.values) {
        final message = updateFailureMessage(kind);
        expect(message.trim(), isNotEmpty, reason: '$kind 缺文案');
        messages.add(message);
      }
      expect(messages.length, UpdateFailureKind.values.length);
    });

    test('签名冲突的文案给出「卸载重装」出路', () {
      final message = updateFailureMessage(UpdateFailureKind.signatureMismatch);
      expect(message.contains('卸载'), isTrue);
    });

    test('权限未授予的文案给出设置路径', () {
      final message = updateFailureMessage(UpdateFailureKind.permissionDenied);
      expect(message.contains('安装未知应用'), isTrue);
    });

    test('异常 toString 带出诊断细节', () {
      const error = UpdateInstallException(
        UpdateFailureKind.signatureMismatch,
        '签名不一致',
        detail: 'abc123',
      );
      expect(error.toString(), contains('abc123'));
    });
  });
}
