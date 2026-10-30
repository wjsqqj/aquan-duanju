import 'dart:convert';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/edge/edge_constants.dart';
import 'package:crypto/crypto.dart';
import 'package:aquan_duanju/core/tts/edge/edge_token.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一组 golden：unix 秒 → ticks / CS64 / SHA-256。
///
/// 期望值全部由真源 `edge-tts/drm.py:_token_hash` 跑出（见
/// `research/cs64_equivalence_probe.py` 的对照输出）。这是**唯一能离线证明
/// 算法正确**的东西，改任何一个字节都会让这里红。
class _Golden {
  const _Golden(this.unixSeconds, this.ticks, this.cs64, this.sha256);

  final int unixSeconds;
  final String ticks;
  final String cs64;
  final String sha256;

  String get token => '$cs64-$sha256';
}

const List<_Golden> _goldens = <_Golden>[
  _Golden(
    1761800000,
    '134062734000000000',
    'C338E44013EC6A42',
    '56CF5AB7E371B3C984C1E1E9DE512F31C46FE3E4F78F93C6B6D37503227DE8BF',
  ),
  _Golden(
    1761830400,
    '134063040000000000',
    'E85EE019F716B9A1',
    'A69C980C6E0B1400EA1365788661B84DA01EF838A7C46357DA47156032BCBFB3',
  ),
  _Golden(
    1793400000,
    '134378736000000000',
    '231C40957F3AC499',
    'A124FAAA06FB90944D0B453C1EFB65F40ADC54B7DE0CDA7E54BB9B82E3360B78',
  ),
];

final RegExp _tokenPattern = RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$');

void main() {
  group('ticks 与被哈希消息', () {
    test('向下对齐到 300 秒（token 五分钟一个）', () {
      expect(alignEdgeUnixSeconds(1761800000), 1761799800);
      expect(alignEdgeUnixSeconds(1761830400), 1761830400);
      expect(alignEdgeUnixSeconds(1761800299), 1761800100);
    });

    test('ticks 是纯整数十进制（18 位），绝不经过 double', () {
      final ticks = edgeFileTimeTicks(alignEdgeUnixSeconds(1761800000));
      expect(ticks, '134062734000000000');
      expect(ticks.contains('.'), isFalse);
      expect(ticks.contains('e'), isFalse);
      // BigInt 复核：int64 与十进制字符串互等，说明没有精度损失。
      expect(BigInt.parse(ticks).toString(), ticks);
      expect(ticks.length, 18);
    });

    test('消息 = 57 字节前缀 + ticks + 客户端标识，总长 107', () {
      final suffix = edgeTokenSuffix(alignEdgeUnixSeconds(1761800000));
      expect(suffix, '134062734000000000$kEdgeTrustedClientToken');
      final message = edgeGecMessage(suffix);
      expect(message.length, 107);
      expect(
        utf8.decode(message.sublist(0, kEdgeGecPrefix.length)),
        kEdgeGecPrefix,
      );
      expect(kEdgeGecPrefix.length, 57);
      // 前 4 个字节参与 CS64 的小端字读取，形状必须稳定。
      expect(message[0], 'C'.codeUnitAt(0));
    });
  });

  group('token v2 golden（真源钉死）', () {
    for (final golden in _goldens) {
      test('unix=${golden.unixSeconds}', () {
        final aligned = alignEdgeUnixSeconds(golden.unixSeconds);
        final suffix = edgeTokenSuffix(aligned);
        final message = edgeGecMessage(suffix);
        expect(edgeFileTimeTicks(aligned), golden.ticks);

        final sha = edgeSha256UpperHex(message);
        expect(sha, golden.sha256);
        expect(
          edgeCs64Hex(
            message,
            Uint8List.fromList(sha256.convert(message).bytes),
          ),
          golden.cs64,
        );
        expect(
          generateSecMsGec(
            now: DateTime.fromMillisecondsSinceEpoch(
              golden.unixSeconds * 1000,
              isUtc: true,
            ),
          ),
          golden.token,
        );
      });
    }
  });

  group('generateSecMsGec', () {
    test('注入 now 后完全确定（无随机），格式是 <16hex>-<64hex> 大写', () {
      final now = DateTime.fromMillisecondsSinceEpoch(
        1761800000 * 1000,
        isUtc: true,
      );
      final first = generateSecMsGec(now: now);
      final second = generateSecMsGec(now: now);
      expect(first, second);
      expect(first, matches(_tokenPattern));
      expect(first.toUpperCase(), first);
      expect(first.length, 81); // 16 + '-' + 64
    });

    test('同一 300 秒窗口内时间戳相同（对齐生效）', () {
      DateTime at(int seconds) =>
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      expect(
        generateSecMsGec(now: at(1761800000)),
        generateSecMsGec(now: at(1761800099)),
      );
      expect(
        generateSecMsGec(now: at(1761800000)),
        isNot(generateSecMsGec(now: at(1761800100))),
      );
    });

    test('skew 等价于把本地时间往前挪', () {
      final now = DateTime.fromMillisecondsSinceEpoch(
        1761800000 * 1000,
        isUtc: true,
      );
      expect(
        generateSecMsGec(now: now, skew: const Duration(seconds: 300)),
        generateSecMsGec(
          now: DateTime.fromMillisecondsSinceEpoch(
            (1761800000 + 300) * 1000,
            isUtc: true,
          ),
        ),
      );
    });
  });

  group('随机标识', () {
    test('ConnectionId / X-RequestId 是 32 位小写 hex，且每次新造', () {
      final a = newEdgeRequestId();
      final b = newEdgeRequestId();
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(b, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a, isNot(b));
    });

    test('muid 是 32 位大写 hex', () {
      expect(generateEdgeMuid(), matches(RegExp(r'^[0-9A-F]{32}$')));
    });
  });

  group('密钥不落日志', () {
    test('指纹只保留哈希前缀与长度，不含原值', () {
      final secret = generateSecMsGec(
        now: DateTime.fromMillisecondsSinceEpoch(
          1761800000 * 1000,
          isUtc: true,
        ),
      );
      final fingerprint = edgeSecretFingerprint(secret);
      expect(fingerprint.contains(secret), isFalse);
      expect(fingerprint.contains('len=${secret.length}'), isTrue);
      expect(
        RegExp(r'^[0-9A-F]{8}/len=\d+$').hasMatch(fingerprint),
        isTrue,
        reason: '前 8 位哈希 + 长度，足够关联同一次失败',
      );
      expect(edgeSecretFingerprint(''), '<empty>');
    });

    test('同一秘密指纹稳定（可跨日志关联）', () {
      expect(edgeSecretFingerprint('abc'), edgeSecretFingerprint('abc'));
      expect(edgeSecretFingerprint('abc'), isNot(edgeSecretFingerprint('abd')));
    });
  });

  group('Date 头解析与时钟纠偏', () {
    test('RFC 1123 GMT', () {
      expect(
        parseHttpDate('Wed, 15 Oct 2025 06:13:20 GMT'),
        DateTime.utc(2025, 10, 15, 6, 13, 20),
      );
    });

    test('数字时区按偏移折算到 UTC', () {
      expect(
        parseHttpDate('Wed, 15 Oct 2025 14:13:20 +0800'),
        DateTime.utc(2025, 10, 15, 6, 13, 20),
      );
      expect(
        parseHttpDate('Wed, 15 Oct 2025 01:13:20 -0500'),
        DateTime.utc(2025, 10, 15, 6, 13, 20),
      );
    });

    test('缺失/畸形/大小写与非英文月份一律 null（不猜）', () {
      expect(parseHttpDate(null), isNull);
      expect(parseHttpDate(''), isNull);
      expect(parseHttpDate('not a date'), isNull);
      expect(parseHttpDate('Wed, 15 Xax 2025 06:13:20 GMT'), isNull);
      expect(
        parseHttpDate('Wed, 15 oct 2025 06:13:20 GMT'),
        DateTime.utc(2025, 10, 15, 6, 13, 20),
      );
    });

    test('纠偏是「补齐到服务端」，重复喂同一个 Date 不会放大两次', () {
      final clock = DrmClock();
      final local = DateTime.utc(2025, 10, 15, 6, 0, 0);
      final server = 'Wed, 15 Oct 2025 06:05:00 GMT';
      expect(clock.adjustFromHttpDate(server, localNow: local), isTrue);
      expect(clock.skew, const Duration(seconds: 300));
      expect(clock.adjustFromHttpDate(server, localNow: local), isTrue);
      expect(clock.skew, const Duration(seconds: 300));
      // 服务端时间往前走，纠偏随之更新。
      expect(
        clock.adjustFromHttpDate(
          'Wed, 15 Oct 2025 06:07:00 GMT',
          localNow: local,
        ),
        isTrue,
      );
      expect(clock.skew, const Duration(seconds: 420));
      clock.reset();
      expect(clock.skew, Duration.zero);
    });

    test('没有 Date 头时返回 false（上游的 SkewAdjustmentError）', () {
      final clock = DrmClock();
      expect(clock.adjustFromHttpDate(null), isFalse);
      expect(clock.skew, Duration.zero);
    });

    test('进程内共享实例可被显式覆写', () {
      DrmClock.shared.skew = const Duration(seconds: -30);
      expect(DrmClock.shared.skew, const Duration(seconds: -30));
      DrmClock.shared.reset();
      expect(DrmClock.shared.skew, Duration.zero);
    });
  });
}
