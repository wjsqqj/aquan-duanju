import 'package:aquan_duanju/update/update_mirror_probe.dart';
import 'package:aquan_duanju/update/update_mirrors.dart';
import 'package:flutter_test/flutter_test.dart';

const _probeUrl =
    'https://github.com/wjsqqj/aquan-duanju/releases/latest/download/update.json';

UpdateMirror _mirror(String id) =>
    UpdateMirror(id: id, label: id, prefix: 'https://$id/');

void main() {
  group('吞吐排序', () {
    test('高吞吐优先于低延迟（老实现的 1 字节探测测不到吞吐）', () {
      final ordered = UpdateMirrorProbe.orderSamples(const [
        // 延迟最低但被限速：这是「1% 要几分钟」的典型源。
        MirrorProbeSample(
          id: 'fast-latency-slow-speed',
          reachable: true,
          latencyMs: 10,
          bytesPerSecond: 20 * 1024,
        ),
        MirrorProbeSample(
          id: 'slow-latency-fast-speed',
          reachable: true,
          latencyMs: 300,
          bytesPerSecond: 4 * 1024 * 1024,
        ),
        MirrorProbeSample(
          id: 'dead',
          reachable: false,
          latencyMs: 1,
          bytesPerSecond: 0,
        ),
      ]);
      expect(
        [for (final s in ordered) s.id],
        <String>['slow-latency-fast-speed', 'fast-latency-slow-speed'],
      );
    });

    test('没有吞吐数据时按延迟升序（兼容测试注入的 ping 路径）', () {
      final ordered = UpdateMirrorProbe.orderSamples(const [
        MirrorProbeSample(id: 'slow', reachable: true, latencyMs: 80),
        MirrorProbeSample(id: 'fast', reachable: true, latencyMs: 5),
      ]);
      expect([for (final s in ordered) s.id], <String>['fast', 'slow']);
    });
  });

  group('UpdateMirrorProbe', () {
    test('按实测延迟排序并过滤不可连通的镜像', () async {
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('slow'), _mirror('fast'), _mirror('dead')],
        ping: (url) async {
          if (url.startsWith('https://dead/')) return false;
          if (url.startsWith('https://slow/')) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return true;
        },
      );

      final result = await probe.probe(_probeUrl);
      expect(result.reachableIds, <String>['fast', 'slow']);
      expect(result.contains('dead'), isFalse);
      expect(result.latencyMs.containsKey('fast'), isTrue);
    });

    test('includeDirect 时直连参与排序', () async {
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('slow')],
        ping: (url) async {
          if (url.startsWith('https://slow/')) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return true;
        },
      );
      final result = await probe.probe(_probeUrl, includeDirect: true);
      expect(result.reachableIds, <String>[kDirectProbeId, 'slow']);
    });

    test('直连不通时只留可达镜像', () async {
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('m')],
        ping: (url) async => !url.startsWith('https://github.com/'),
      );
      final result = await probe.probe(_probeUrl, includeDirect: true);
      expect(result.reachableIds, <String>['m']);
      expect(result.contains(kDirectProbeId), isFalse);
    });

    test('清单地址不是 GitHub 域名时不发起探测', () async {
      var calls = 0;
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('m')],
        ping: (_) async {
          calls++;
          return true;
        },
      );

      final result = await probe.probe('https://example.com/update.json');
      expect(result.isEmpty, isTrue);
      expect(calls, 0);
    });

    test('缓存窗口内不重复探测，过期后重探', () async {
      var now = DateTime(2026, 11, 11, 12);
      var calls = 0;
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('m')],
        ping: (_) async {
          calls++;
          return true;
        },
        clock: () => now,
        cacheTtl: const Duration(minutes: 10),
      );

      await probe.probe(_probeUrl);
      expect(calls, 1);
      await probe.probe(_probeUrl);
      expect(calls, 1, reason: '缓存命中不应重新探测');
      expect(probe.cached(_probeUrl)?.reachableIds, <String>['m']);

      now = now.add(const Duration(minutes: 11));
      await probe.probe(_probeUrl);
      expect(calls, 2);
    });

    test('全灭不写缓存：下次仍会重探', () async {
      var calls = 0;
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('m')],
        ping: (_) async {
          calls++;
          return false;
        },
      );

      expect((await probe.probe(_probeUrl)).isEmpty, isTrue);
      expect((await probe.probe(_probeUrl)).isEmpty, isTrue);
      expect(calls, 2);
      expect(probe.cached(_probeUrl), isNull);
    });

    test('并发调用合并为一次探测', () async {
      var calls = 0;
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('m')],
        ping: (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        },
      );

      final results = await Future.wait([
        probe.probe(_probeUrl),
        probe.probe(_probeUrl),
      ]);
      expect(calls, 1);
      expect(results.every((r) => r.reachableIds.length == 1), isTrue);
    });

    test('invalidate 丢弃缓存', () async {
      var calls = 0;
      final probe = UpdateMirrorProbe(
        mirrors: [_mirror('m')],
        ping: (_) async {
          calls++;
          return true;
        },
      );

      await probe.probe(_probeUrl);
      probe.invalidate();
      expect(probe.cached(_probeUrl), isNull);
      await probe.probe(_probeUrl);
      expect(calls, 2);
    });
  });
}
