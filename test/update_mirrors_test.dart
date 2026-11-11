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

  group('域名替换型镜像（kkgithub）', () {
    const mirror = UpdateMirror(
      id: 'kkgithub',
      label: 'kkgithub.com',
      mode: UpdateMirrorMode.hostReplace,
      hostMap: {
        'github.com': 'kkgithub.com',
        'raw.githubusercontent.com': 'raw.kkgithub.com',
        'objects.githubusercontent.com': 'objects.kkgithub.com',
      },
    );

    test('三种 GitHub 自有域名按映射替换', () {
      expect(
        mirror.resolve('https://github.com/a/b/releases/download/v1/x.exe'),
        'https://kkgithub.com/a/b/releases/download/v1/x.exe',
      );
      expect(
        mirror.resolve('https://raw.githubusercontent.com/a/b/main/update.json'),
        'https://raw.kkgithub.com/a/b/main/update.json',
      );
      expect(
        mirror.resolve('https://objects.githubusercontent.com/a?token=1'),
        'https://objects.kkgithub.com/a?token=1',
      );
    });

    test('未映射的 host / 非 https / 相对地址拒绝', () {
      // api.github.com 在 kkgithub 上没有对应域名：不能猜，只能返回 null。
      expect(mirror.resolve('https://api.github.com/repos/a/b'), isNull);
      expect(mirror.resolve('https://release-assets.githubusercontent.com/a'),
          isNull);
      expect(mirror.resolve('http://github.com/a'), isNull);
      expect(mirror.resolve('https://evil.example.com/a'), isNull);
      expect(mirror.resolve('/relative/path'), isNull);
    });

    test('不支持 API 代理', () {
      expect(mirror.resolveApi('https://api.github.com/repos/a/b'), isNull);
    });
  });

  group('内置镜像清单', () {
    test('只保留实测可用的镜像', () {
      final ids = builtInUpdateMirrors.map((m) => m.id).toList();
      expect(ids, <String>[
        'gh-proxy',
        'gh-proxy-hk',
        'gh-noki',
        'cors-isteed',
        'boki-moe',
        'monkeyray',
      ]);
      expect(ids.toSet().length, ids.length, reason: 'id 必须唯一（进健康缓存）');
    });

    test('实测不可用的镜像不再入列', () {
      final ids = builtInUpdateMirrors.map((m) => m.id).toSet();
      // ghfast.top / kkgithub.com 连接失败；hub.gitmirror.com 域名 NXDOMAIN；
      // ghproxy.net 长时间无响应；ghproxy.cfd 返回 200 + HTML 落地页（假可用）。
      for (final dead in <String>[
        'ghfast',
        'kkgithub',
        'gitmirror',
        'ghproxy-net',
        'ghproxy-cfd',
      ]) {
        expect(ids.contains(dead), isFalse, reason: '$dead 应当已移除');
      }
    });

    test('能代理 api.github.com 的只有实测通过的三个', () {
      final api = builtInUpdateMirrors
          .where((m) => m.proxiesApi)
          .map((m) => m.id)
          .toList();
      // cors.isteed.cc / github.boki.moe / ghproxy.monkeyray.net 实测 API 403/404，
      // 只能下载资产；清单与资产走 resolve()，API 兜底才需要 proxiesApi。
      expect(api, <String>['gh-proxy', 'gh-proxy-hk', 'gh-noki']);
    });
  });
}
