import 'dart:ui' as ui;

import 'package:aquan_duanju/core/danmaku/danmaku_emoji.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  double measure(String s) => s.length * 10.0;

  group('弹幕表情短码解析', () {
    test('官方短码直接命中', () {
      final rich = buildDanmakuRichText('[鼓掌]',
        emojiBoxWidth: 20, measureText: measure);
      expect(rich.hasEmoji, isTrue);
      expect(rich.displayText, '\u3000');
      expect(rich.stickers.single.canonical, '[鼓掌]');
      expect(rich.offsets, [0]);
    });

    test('红果别名映射到官方短码', () {
      final rich = buildDanmakuRichText('太爽了[爽]',
        emojiBoxWidth: 20, measureText: measure);
      expect(rich.stickers.single.canonical, '[好开心]');
      expect(rich.displayText, '太爽了\u3000');
      expect(rich.offsets, [30]);
    });

    test('多条表情的偏移按占位宽度累加', () {
      final rich = buildDanmakuRichText('前[笑哭]后[鼓掌]',
        emojiBoxWidth: 20, measureText: measure);
      expect(rich.displayText, '前\u3000后\u3000');
      expect(rich.offsets, [10, 40]);
    });

    test('未收录短码原样保留为文字', () {
      const text = '看看[火星表情]吧';
      final rich = buildDanmakuRichText(text,
        emojiBoxWidth: 20, measureText: measure);
      expect(rich.hasEmoji, isFalse);
      expect(rich.displayText, text);
      expect(rich.stickers, isEmpty);
    });

    test('×N 合并后缀不影响表情解析', () {
      final rich = buildDanmakuRichText('太赞了[赞] ×3',
        emojiBoxWidth: 20, measureText: measure);
      expect(rich.hasEmoji, isTrue);
      expect(rich.displayText, '太赞了\u3000 ×3');
      expect(rich.stickers.single.canonical, '[赞]');
    });

    test('空串不产生段', () {
      final rich = buildDanmakuRichText('',
        emojiBoxWidth: 20, measureText: measure);
      expect(rich.hasEmoji, isFalse);
      expect(rich.displayText, isEmpty);
    });
  });

  group('内置资源', () {
    test('表情图片随包内置且可解码', () async {
      final ByteData data = await rootBundle
          .load('assets/danmaku_emoji/e000.webp')
          .timeout(const Duration(seconds: 15));
      final ui.Codec codec = await ui
          .instantiateImageCodec(data.buffer.asUint8List(), targetWidth: 40)
          .timeout(const Duration(seconds: 15));
      final ui.FrameInfo frame =
          await codec.getNextFrame().timeout(const Duration(seconds: 15));
      expect(frame.image.width, greaterThan(0));
      frame.image.dispose();
      codec.dispose();
    });
  });

  group('表情注册表', () {
    test('别名与官方短码都识别', () {
      final registry = DanmakuEmojiRegistry.instance;
      expect(registry.canonicalOf('[爽]'), '[好开心]');
      expect(registry.isKnown('[爽]'), isTrue);
      expect(registry.isKnown('[鼓掌]'), isTrue);
      expect(registry.isKnown('[火星表情]'), isFalse);
    });
  });
}
