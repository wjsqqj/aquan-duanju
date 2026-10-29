import 'package:aquan_duanju/update/update_mirror_health.dart';
import 'package:aquan_duanju/update/update_mirrors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateMirror.resolve', () {
    const mirror = UpdateMirror(
      id: 'm',
      label: 'm',
      prefix: 'https://gh-proxy.com/',
      proxiesApi: true,
    );

    test('github 资产地址改写', () {
      expect(
        mirror.resolve(
            'https://github.com/wjsqqj/aquan-duanju/releases/download/v1/x.exe'),
        'https://gh-proxy.com/https://github.com/wjsqqj/aquan-duanju/releases/download/v1/x.exe',
      );
    });

    test('api.github.com 可代理', () {
      expect(
        mirror.resolveApi('https://api.github.com/repos/a/b/releases/latest'),
        'https://gh-proxy.com/https://api.github.com/repos/a/b/releases/latest',
      );
    });

    test('非 https / 非 github 域名拒绝', () {
      expect(mirror.resolve('http://github.com/a'), isNull);
      expect(mirror.resolve('https://evil.example.com/a'), isNull);
      expect(mirror.resolve('/relative'), isNull);
    });

    test('不支持 API 代理的镜像 resolveApi 返回 null', () {
      const assetOnly = UpdateMirror(
        id: 'a',
        label: 'a',
        prefix: 'https://ghfast.top/',
      );
      expect(assetOnly.resolveApi('https://api.github.com/x'), isNull);
      expect(assetOnly.resolve('https://objects.githubusercontent.com/a'),
          'https://ghfast.top/https://objects.githubusercontent.com/a');
    });
  });

  group('MirrorHealth', () {
    test('冷却窗口', () {
      final now = DateTime(2026, 10, 29, 12);
      final health = MirrorHealth(
        lastFailAt: now.millisecondsSinceEpoch - 5 * 60 * 1000,
        consecutiveFailures: 1,
      );
      expect(health.isCoolingDown(now, const Duration(minutes: 30)), isTrue);
      expect(
        health.isCoolingDown(
            now.add(const Duration(minutes: 40)), const Duration(minutes: 30)),
        isFalse,
      );
    });

    test('从未失败不冷却', () {
      expect(
        const MirrorHealth().isCoolingDown(
            DateTime(2026), const Duration(minutes: 30)),
        isFalse,
      );
    });

    test('坏 JSON 回落默认值', () {
      final h = MirrorHealth.fromJson({'lastFailAt': 'bad'});
      expect(h.consecutiveFailures, 0);
      expect(h.lastFailAt, 0);
    });
  });
}
