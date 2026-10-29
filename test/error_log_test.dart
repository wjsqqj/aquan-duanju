import 'package:aquan_duanju/core/error_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorLog', () {
    test('记录与容量上限', () {
      var tick = 0;
      final log = ErrorLog(now: () => DateTime(2026, 1, 1, 0, 0, tick++));
      for (var i = 0; i < ErrorLog.maxEntries + 5; i++) {
        log.record('测试', '错误 $i');
      }
      expect(log.length, ErrorLog.maxEntries);
      expect(log.text, contains('错误 5'));
      expect(log.text, isNot(contains('错误 4')));
    });

    test('脱敏 URL 查询串 / 凭据 / 解密密钥', () {
      final redacted = ErrorLog.redact(
        'open https://x/a?token=secret&id=1 '
        'Authorization: Bearer abc123 '
        'decryption_key=0123456789abcdef0123456789abcdef',
      );
      expect(redacted, isNot(contains('secret')));
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, isNot(contains('0123456789abcdef0123456789abcdef')));
      expect(redacted, contains('https://x/a?…'));
    });

    test('clear 清空', () {
      final log = ErrorLog()..record('测试', 'x');
      expect(log.isEmpty, isFalse);
      log.clear();
      expect(log.isEmpty, isTrue);
    });
  });
}
