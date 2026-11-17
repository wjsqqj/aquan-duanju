import 'package:aquan_duanju/update/update_manifest.dart';
import 'package:aquan_duanju/update/update_manifest_fanout.dart';
import 'package:flutter_test/flutter_test.dart';

UpdateManifest _manifest(String version, {int code = 0}) => UpdateManifest(
  version: version,
  versionCode: code,
  assets: const <String, List<String>>{
    'windows': <String>[
      'https://github.com/wjsqqj/aquan-duanju/releases/download/v0/x.exe',
    ],
  },
);

ManifestCandidate<String> _candidate(String id, String version, {int code = 0}) =>
    ManifestCandidate<String>(item: id, manifest: _manifest(version, code: code));

String? _winnerId(ManifestSelection<String>? selection) =>
    selection?.winner.item;

void main() {
  group('selectFreshestManifest（版本优先）', () {
    test('快但旧的源不敌慢但新的源（11-17 现场：1.12.9 vs 1.12.10）', () {
      final selection = selectFreshestManifest<String>([
        _candidate('cors-isteed（最快）', '1.12.9'),
        _candidate('gh-proxy（较慢）', '1.12.10'),
        _candidate('direct（最慢）', '1.12.10'),
      ]);
      expect(_winnerId(selection), 'gh-proxy（较慢）');
      expect(selection!.version, '1.12.10');
      expect(selection.behind.length, 1);
      expect(selection.behind.single.candidate.item, 'cors-isteed（最快）');
      expect(selection.behind.single.note, 'v1.12.9 < v1.12.10');
    });

    test('版本相同时取输入顺序靠前的（即测速最快）', () {
      final selection = selectFreshestManifest<String>([
        _candidate('fast', '1.12.10'),
        _candidate('slow', '1.12.10'),
      ]);
      expect(_winnerId(selection), 'fast');
      expect(selection!.behind, isEmpty, reason: '同版本落选不算落后');
    });

    test('同版本按 versionCode 兜底（构建号更大的赢）', () {
      final selection = selectFreshestManifest<String>([
        _candidate('code87', '1.12.10', code: 87),
        _candidate('code88', '1.12.10', code: 88),
      ]);
      expect(_winnerId(selection), 'code88');
      expect(selection!.behind.single.note, 'v1.12.10(87) < v1.12.10(88)');
    });

    test('版本号优先于构建号（1.13.0(0) 胜过 1.12.10(88)）', () {
      final selection = selectFreshestManifest<String>([
        _candidate('old', '1.12.10', code: 88),
        _candidate('new', '1.13.0', code: 1),
      ]);
      expect(_winnerId(selection), 'new');
    });

    test('多个落后源全部列出（用于一条日志）', () {
      final selection = selectFreshestManifest<String>([
        _candidate('a', '1.10.0'),
        _candidate('b', '1.12.0'),
        _candidate('c', '1.12.10'),
      ]);
      expect(_winnerId(selection), 'c');
      expect(
        selection!.behind.map((b) => b.candidate.item),
        <String>['a', 'b'],
      );
    });

    test('空候选返回 null（全部源抓不到清单 → 走 API / 离线兜底）', () {
      expect(selectFreshestManifest<String>(const []), isNull);
    });

    test('单候选直接胜出', () {
      final selection = selectFreshestManifest<String>([
        _candidate('only', '1.0.0'),
      ]);
      expect(_winnerId(selection), 'only');
      expect(selection!.behind, isEmpty);
    });

    test('behind 与 winner 都是不可变视图（防止调用方改列表）', () {
      final selection = selectFreshestManifest<String>([
        _candidate('a', '1.0.0'),
        _candidate('b', '1.1.0'),
      ])!;
      expect(
        () => selection.behind.add(
          ManifestBehind<String>(
            candidate: selection.winner,
            note: 'x',
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('compareManifestVersions', () {
    test('语义版本逐段比较', () {
      expect(
        compareManifestVersions(_manifest('1.12.10'), _manifest('1.12.9')),
        greaterThan(0),
      );
      expect(
        compareManifestVersions(_manifest('1.9.0'), _manifest('1.12.0')),
        lessThan(0),
      );
      expect(
        compareManifestVersions(_manifest('2.0.0'), _manifest('1.99.99')),
        greaterThan(0),
      );
    });

    test('版本相同才看 versionCode', () {
      expect(
        compareManifestVersions(
          _manifest('1.12.10', code: 88),
          _manifest('1.12.10', code: 88),
        ),
        0,
      );
      expect(
        compareManifestVersions(
          _manifest('1.12.10', code: 88),
          _manifest('1.12.10', code: 87),
        ),
        greaterThan(0),
      );
    });
  });
}
