import 'package:aquan_duanju/widgets/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isDanmakuBlocked', () {
    test('空屏蔽表不过滤任何文本', () {
      expect(isDanmakuBlocked('前方高能', const {}), isFalse);
    });

    test('普通词：大小写不敏感的包含匹配', () {
      expect(isDanmakuBlocked('前方广告预警', {'广告'}), isTrue);
      expect(isDanmakuBlocked('前方广告预警', {'广 告'}), isFalse);
      expect(isDanmakuBlocked('This is SPAM', {'spam'}), isTrue);
      expect(isDanmakuBlocked('正常弹幕', {'广告', '剧透'}), isFalse);
    });

    test('re: 前缀按正则匹配', () {
      expect(isDanmakuBlocked('这是广告别信', {'re:广告|剧透'}), isTrue);
      expect(isDanmakuBlocked('这是剧透预警', {'re:广告|剧透'}), isTrue);
      expect(isDanmakuBlocked('正常弹幕', {'re:广告|剧透'}), isFalse);
    });

    test('非法正则跳过，不影响其他词', () {
      expect(isDanmakuBlocked('含广告的内容', {'re:([unclosed', '广告'}), isTrue);
      expect(isDanmakuBlocked('正常弹幕', {'re:([unclosed'}), isFalse);
    });

    test('正则大小写不敏感', () {
      expect(isDanmakuBlocked('Buy NOW', {r're:buy\s+now'}), isTrue);
    });
  });
}
