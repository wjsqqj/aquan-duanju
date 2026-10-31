import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/subtitle_converter.dart';

void main() {
  group('srtToVtt', () {
    test('标准 SRT：序号去除、逗号变点、WEBVTT 头', () {
      const srt = '1\n00:00:01,000 --> 00:00:03,500\n第一行\n第二行\n\n'
          '2\n00:01:02,500 --> 00:01:05,000\n第二条\n';
      final vtt = srtToVtt(srt);
      expect(vtt.startsWith('WEBVTT'), isTrue);
      expect(vtt.contains('00:00:01.000 --> 00:00:03.500'), isTrue);
      expect(vtt.contains('00:01:02.500 --> 00:01:05.000'), isTrue);
      expect(vtt.contains('第一行'), isTrue);
      expect(vtt.contains('第二行'), isTrue);
      expect(vtt.contains('第二条'), isTrue);
      // 序号行不保留。
      expect(RegExp(r'^\s*2\s*$', multiLine: true).hasMatch(vtt), isFalse);
    });

    test('单数字小时与 BOM 容错', () {
      const srt = '\ufeff1\n0:00:01,5 --> 0:00:02,750\n短小时\n';
      final vtt = srtToVtt(srt);
      expect(vtt.contains('00:00:01.500 --> 00:00:02.750'), isTrue);
      expect(vtt.contains('短小时'), isTrue);
    });

    test('多行字幕文本保留', () {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\n上\n下\n';
      final vtt = srtToVtt(srt);
      expect(vtt.contains('上\n下'), isTrue);
    });
  });
}
