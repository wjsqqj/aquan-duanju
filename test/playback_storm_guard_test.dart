import 'package:aquan_duanju/core/playback_storm_guard.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _ms(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

void main() {
  group('PlaybackStormGuard', () {
    test('窗口内同文本第 3 次起判定为风暴', () {
      final g = PlaybackStormGuard();
      expect(g.shouldSuppress('err-a', _ms(0)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(200)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(400)), isTrue, reason: '第 3 次 → 风暴');
      expect(g.lastStormHits, 3);
      expect(g.suppressedCount, 1);
      // 同一场风暴的后续命中继续压制。
      expect(g.shouldSuppress('err-a', _ms(600)), isTrue);
      expect(g.suppressedCount, 2);
    });

    test('不同文本互不干扰（换线后新错误文案不该被误伤）', () {
      final g = PlaybackStormGuard();
      expect(g.shouldSuppress('err-a', _ms(0)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(100)), isFalse);
      expect(g.shouldSuppress('err-b', _ms(200)), isFalse);
      expect(g.shouldSuppress('err-b', _ms(300)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(400)), isTrue, reason: 'err-a 第 3 次');
      expect(g.shouldSuppress('err-b', _ms(500)), isTrue, reason: 'err-b 第 3 次');
    });

    test('滑动窗口过期后恢复正常计数', () {
      final g = PlaybackStormGuard();
      expect(g.shouldSuppress('err-a', _ms(0)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(200)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(400)), isTrue);
      // 旧命中全部滑出 1s 窗口：重新从 1 开始计。
      expect(g.shouldSuppress('err-a', _ms(1500)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(1700)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(1900)), isTrue);
      expect(g.lastStormHits, 3);
    });

    test('reset 清空一切状态（成功开播后重新计数）', () {
      final g = PlaybackStormGuard();
      g.shouldSuppress('err-a', _ms(0));
      g.shouldSuppress('err-a', _ms(100));
      expect(g.shouldSuppress('err-a', _ms(200)), isTrue);
      g.reset();
      expect(g.suppressedCount, 0);
      expect(g.lastStormHits, 0);
      expect(g.shouldSuppress('err-a', _ms(300)), isFalse);
      expect(g.shouldSuppress('err-a', _ms(400)), isFalse);
    });
  });
}
