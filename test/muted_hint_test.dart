import 'package:aquan_duanju/core/muted_hint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MutedPlaybackHintRegistry', () {
    test('同一部剧只提醒一次', () {
      final r = MutedPlaybackHintRegistry();
      expect(r.shouldHint('t:剧A'), isTrue);
      expect(r.shouldHint('t:剧A'), isFalse);
      expect(r.shouldHint('t:剧B'), isTrue);
    });

    test('空键不提醒', () {
      final r = MutedPlaybackHintRegistry();
      expect(r.shouldHint(''), isFalse);
    });

    test('超出容量淘汰最旧', () {
      final r = MutedPlaybackHintRegistry(capacity: 2);
      expect(r.shouldHint('a'), isTrue);
      expect(r.shouldHint('b'), isTrue);
      expect(r.shouldHint('c'), isTrue);
      expect(r.alreadyHinted('a'), isFalse);
      expect(r.shouldHint('a'), isTrue);
    });

    test('身份键优先标题', () {
      expect(MutedPlaybackHintRegistry.keyFor(title: ' 剧名 ', url: 'u'), 't:剧名');
      expect(MutedPlaybackHintRegistry.keyFor(url: ' u '), 'u:u');
      expect(MutedPlaybackHintRegistry.keyFor(), '');
    });
  });
}
