import 'dart:convert';

import 'package:aquan_duanju/core/tts/edge/edge_constants.dart';
import 'package:aquan_duanju/core/tts/edge/edge_ssml.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐块长度核算用：与引擎同一口径（转义后的 UTF-8 字节数）。
int _bytesOf(String source, EdgeSpeakRange range) =>
    escapedUtf8Bytes(range.slice(source));

bool _isHigh(int code) => code >= 0xD800 && code <= 0xDBFF;
bool _isLow(int code) => code >= 0xDC00 && code <= 0xDFFF;

void main() {
  group('转义与还原成对（只转 & < >）', () {
    test('引号与撇号原样保留：多转一个字符，token 就对不上原文', () {
      const raw = '他说："你好" & <b> \'x\'';
      final escaped = ssmlEscapeText(raw);
      expect(escaped, '他说："你好" &amp; &lt;b&gt; \'x\'');
      expect(escaped.contains('&quot;'), isFalse);
      expect(escaped.contains('&#39;'), isFalse);
      expect(ssmlUnescapeText(escaped), raw);
    });

    test('往返：含实体的原文也不会串位', () {
      const samples = <String>[
        '&',
        '&amp;',
        '&lt;',
        '<a href="x">&amp;</a>',
        'A & B < C > D',
        '中文 & 英文',
        '&am;',
        '',
      ];
      for (final sample in samples) {
        expect(ssmlUnescapeText(ssmlEscapeText(sample)), sample);
      }
    });

    test('还原顺序正确：先解 &lt;/&gt; 再解 &amp;（否则会二次解码）', () {
      expect(ssmlUnescapeText('&amp;lt;'), '&lt;');
      expect(ssmlUnescapeText('&amp;amp;'), '&amp;');
    });
  });

  group('不可支持字符清洗', () {
    test('控制字符变空格、长度不变（坐标不漂的前提）', () {
      final dirty = String.fromCharCodes(<int>[
        0x00,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x0E,
        0x1F,
        0x20,
      ]);
      final clean = removeIncompatibleCharacters(dirty);
      expect(clean.length, dirty.length);
      // tab / LF / CR 是合法 XML 空白，必须原样留着（分块要靠它们找切点）。
      expect(clean.codeUnits, <int>[
        0x20,
        0x20,
        0x20,
        0x09,
        0x0A,
        0x20,
        0x20,
        0x0D,
        0x20,
        0x20,
        0x20,
      ]);
    });

    test('干净文本原样返回', () {
      const text = '正常中文，标点。\n换行。';
      expect(removeIncompatibleCharacters(text), text);
    });
  });

  group('音色短名 → Azure 全名', () {
    test('普通短名', () {
      expect(
        azureVoiceName('zh-CN-XiaoxiaoNeural'),
        'Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)',
      );
    });

    test('区域方言把首段并进 region，否则括号里变三段', () {
      expect(
        azureVoiceName('zh-CN-liaoning-XiaobeiNeural'),
        'Microsoft Server Speech Text to Speech Voice '
        '(zh-CN-liaoning, XiaobeiNeural)',
      );
      expect(
        azureVoiceName('en-AU-NatashaNeural'),
        'Microsoft Server Speech Text to Speech Voice (en-AU, NatashaNeural)',
      );
    });

    test('已经是全名的原样返回', () {
      const full =
          'Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)';
      expect(azureVoiceName(full), full);
    });

    test('认不出来的名字直接抛（宁炸不静默换音色）', () {
      expect(() => azureVoiceName('xiaoxiao'), throwsFormatException);
      expect(() => azureVoiceName('zh-CN-Xiaoxiao'), throwsFormatException);
      expect(() => azureVoiceName(''), throwsFormatException);
    });
  });

  group('prosody 校验', () {
    test('rate/volume 只接受带符号百分数，pitch 只接受带符号 Hz', () {
      expect(validateProsody('rate', '+0%', kEdgeRatePattern), '+0%');
      expect(validateProsody('rate', '-20%', kEdgeRatePattern), '-20%');
      expect(validateProsody('volume', '+100%', kEdgeRatePattern), '+100%');
      expect(validateProsody('pitch', '+3Hz', kEdgePitchPattern), '+3Hz');
      expect(validateProsody('pitch', '-50Hz', kEdgePitchPattern), '-50Hz');
    });

    test('缺符号或写相对值一律拒绝（上游同样只认这两个正则）', () {
      for (final bad in <String>['10%', '+10', '10', 'x-high', '+0Hz', '']) {
        expect(
          () => validateProsody('rate', bad, kEdgeRatePattern),
          throwsFormatException,
          reason: bad,
        );
      }
      for (final bad in <String>['+3', '3Hz', '+3%', 'high']) {
        expect(
          () => validateProsody('pitch', bad, kEdgePitchPattern),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('SSML 形状（服务端只认 Edge 自己会生成的那一种）', () {
    test('属性全单引号、xml:lang 硬编码 en-US、无 express-as/break/mark', () {
      final ssml = buildSsml(voice: 'zh-CN-XiaoxiaoNeural', text: '你好，世界');
      expect(
        ssml,
        "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        "<voice name='Microsoft Server Speech Text to Speech Voice "
        "(zh-CN, XiaoxiaoNeural)'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>你好，世界</prosody>"
        '</voice></speak>',
      );
      expect(ssml.contains('express-as'), isFalse);
      expect(ssml.contains('<break'), isFalse);
      expect(ssml.contains('<mark'), isFalse);
      expect(ssml.contains('xmlns:mstts'), isFalse);
      expect(ssml.contains('"'), isFalse); // 双引号一个都不该有。
      expect(ssml.contains('xml:lang=\'zh-CN\''), isFalse);
    });

    test('正文里的尖括号被转义，不会破坏 XML 结构', () {
      final ssml = buildSsml(voice: 'zh-CN-XiaoxiaoNeural', text: '<b>hi</b>');
      expect(ssml.contains('<b>'), isFalse);
      expect(ssml.contains('&lt;b&gt;'), isTrue);
    });

    test('escapeText=false 时不再二次转义（分块路径先切再转）', () {
      final ssml = buildSsml(
        voice: 'zh-CN-XiaoxiaoNeural',
        text: '&amp;',
        escapeText: false,
      );
      expect(ssml.contains('&amp;amp;'), isFalse);
      expect(ssml.contains('&amp;'), isTrue);
    });

    test('非法韵律在构造期就抛，不会拼出非法属性', () {
      expect(
        () => buildSsml(voice: 'zh-CN-XiaoxiaoNeural', text: 'a', rate: '10%'),
        throwsFormatException,
      );
    });
  });

  group('分块：按转义后的字节预算切，且不复刻上游的越界 bug', () {
    test('预算内只一块，首尾空白从区间里扣掉（坐标仍指向原文）', () {
      const text = '  你好世界  ';
      final ranges = splitSpeakRanges(text);
      expect(ranges.length, 1);
      expect(ranges.single.start, 2);
      expect(ranges.single.end, 6);
      expect(ranges.single.slice(text), '你好世界');
    });

    test('纯空白不产出块', () {
      expect(splitSpeakRanges(''), isEmpty);
      expect(splitSpeakRanges('   \n\t '), isEmpty);
    });

    test('装得下就不切：空格不该把一句短句拆成两块', () {
      const text = '你 & 我';
      final ranges = splitSpeakRanges(text);
      expect(ranges, hasLength(1));
      expect(ranges.single.slice(text), text);
    });

    test('无空格的长中文：每块都 ≤4096 字节（上游会产出一个超大块）', () {
      final text = '啊' * 3000; // 9000 字节
      final ranges = splitSpeakRanges(text);
      expect(ranges.length, 3);
      for (final range in ranges) {
        expect(
          _bytesOf(text, range) <= kEdgeMaxChunkBytes,
          isTrue,
          reason: '$range = ${_bytesOf(text, range)} 字节',
        );
      }
      expect(ranges[0].end - ranges[0].start, 1365); // 4095 字节
      expect(ranges[1].start, 1365);
      expect(ranges[2].start, 2730);
      expect(ranges.last.end, 3000);
      // 覆盖完整：拼起来就是原文（无空白可扣的情况）。
      final joined = ranges.map((r) => r.slice(text)).join();
      expect(joined, text);
    });

    test('连续 ASCII 也严格不超限（上游按整段剩余文本找切点，实测会超）', () {
      final text = 'x' * 9000;
      final ranges = splitSpeakRanges(text);
      for (final range in ranges) {
        expect(_bytesOf(text, range) <= kEdgeMaxChunkBytes, isTrue);
      }
      expect(ranges.map((r) => r.slice(text)).join(), text);
    });

    test('优先在空格后断开，不把词劈成两半', () {
      final text = ('hello ' * 900).trimRight(); // 6300 字节 → 多块
      final ranges = splitSpeakRanges(text);
      expect(ranges.length, greaterThan(1));
      for (final range in ranges.take(ranges.length - 1)) {
        expect(range.slice(text).endsWith(' '), isFalse);
        expect(text[range.end], ' ', reason: '切点应紧跟空格之后');
      }
    });

    test('代理对不被劈开（每块都以完整码点收尾）', () {
      final text = '😀' * 1200; // 4800 字节
      final ranges = splitSpeakRanges(text);
      expect(ranges.length, greaterThan(1));
      for (final range in ranges) {
        expect(_isLow(text.codeUnitAt(range.start)), isFalse);
        if (range.end < text.length) {
          expect(
            _isHigh(text.codeUnitAt(range.end - 1)),
            isFalse,
            reason: '块尾不能停在高位代理上',
          );
        }
        expect((range.end - range.start) % 2, 0);
        expect(_bytesOf(text, range) <= kEdgeMaxChunkBytes, isTrue);
      }
      expect(ranges.map((r) => r.slice(text)).join(), text);
    });

    test('源文本自带实体时，切点不劈开实体', () {
      final text = '前缀内容&amp;后缀' * 400;
      final ranges = splitSpeakRanges(text);
      expect(ranges.length, greaterThan(1));
      for (final range in ranges) {
        expect(_bytesOf(text, range) <= kEdgeMaxChunkBytes, isTrue);
        final slice = range.slice(text);
        final amp = slice.lastIndexOf('&');
        if (amp >= 0) {
          expect(
            slice.indexOf(';', amp),
            greaterThan(-1),
            reason: '$range 结尾留下未闭合的 &',
          );
        }
      }
      expect(ranges.map((r) => r.slice(text)).join(), text);
    });

    test('裸 & 不是实体：切点不该退回到它前面', () {
      // 退避只针对真正的实体：如果把 `&` 一律当实体起点，`你 & 我` 会被
      // 切成三块，而每块都要新建一条 WSS。
      const text = '你 & 我';
      final ranges = splitSpeakRanges(text, maxBytes: 9);
      expect(ranges.length, 2);
      expect(ranges.last.slice(text), '& 我');
    });

    test('自定义预算同样生效（小预算多块）', () {
      final text = 'abcdefghij' * 10;
      final ranges = splitSpeakRanges(text, maxBytes: 24);
      for (final range in ranges) {
        expect(_bytesOf(text, range) <= 24, isTrue);
      }
      expect(ranges.map((r) => r.slice(text)).join(), text);
    });
  });

  group('字节口径', () {
    test('转义后的 UTF-8 字节数与 utf8 编码一致', () {
      const samples = <String>['abc', '中文', '😀', 'a&b<c>d', '混合 & 文本 😀'];
      for (final sample in samples) {
        expect(escapedUtf8Bytes(sample), _realEscapedBytes(sample));
      }
    });

    test('码点口径与码元口径对代理对也一致', () {
      const text = '😀a啊';
      expect(escapedCodePointBytes(text, 0), 4);
      expect(escapedCodePointBytes(text, 2), 1);
      expect(escapedCodePointBytes(text, 3), 3);
      expect(escapedUtf8Bytes(text), 8);
    });
  });

  group('JS 风格时间戳', () {
    test('零填充的日、英文月/周缩写、UTC 全称', () {
      expect(
        jsStyleDate(DateTime.utc(2025, 10, 15, 6, 13, 20)),
        'Wed Oct 15 2025 06:13:20 GMT+0000 (Coordinated Universal Time)',
      );
      expect(
        jsStyleDate(DateTime.utc(2025, 7, 1, 0, 0, 0)),
        'Tue Jul 01 2025 00:00:00 GMT+0000 (Coordinated Universal Time)',
      );
    });

    test('本地时间先换 UTC（周几不能按本地算）', () {
      final local = DateTime.utc(2025, 12, 31, 23, 30, 0);
      expect(jsStyleDate(local).startsWith('Wed Dec 31 2025'), isTrue);
    });
  });
}

/// 参照实现（oracle）：真的转义一次再按 UTF-8 编码数字节。
int _realEscapedBytes(String text) => utf8.encode(ssmlEscapeText(text)).length;
