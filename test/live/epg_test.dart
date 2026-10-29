import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/live/epg.dart';

const _xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="cctv1"><display-name>CCTV-1 综合</display-name></channel>
  <channel id="hunan"><display-name>湖南卫视</display-name></channel>
  <programme start="20261030080000 +0800" stop="20261030090000 +0800" channel="cctv1">
    <title>朝闻天下</title><desc>早间新闻</desc>
  </programme>
  <programme start="20261030090000 +0800" stop="20261030100000 +0800" channel="cctv1">
    <title>电视剧剧场</title>
  </programme>
  <programme start="20261030020000 +0000" stop="20261030040000 Z" channel="hunan">
    <title>金鹰剧场</title>
  </programme>
</tv>
''';

void main() {
  final guide = parseEpgXml(_xml);

  group('parseEpgXml', () {
    test('时间解析（带时区偏移 / Z 结尾）', () {
      final cctv1 = guide.nowFor(['cctv1'], _utc(2026, 10, 30, 0, 30));
      expect(cctv1?.title, '朝闻天下');
      // 湖南卫视的 02:00Z = 北京 10:00，查询 02:30Z。
      final hunan = guide.nowFor(['hunan'], _utc(2026, 10, 30, 2, 30));
      expect(hunan?.title, '金鹰剧场');
    });

    test('now/next 边界（start 含于区间，stop 开区间）', () {
      final at8 = _utc(2026, 10, 30, 0, 0);
      expect(guide.nowFor(['cctv1'], at8)?.title, '朝闻天下');
      expect(guide.nextFor(['cctv1'], at8)?.title, '电视剧剧场');
      // stop 开区间：9:00 整已切换。
      expect(guide.nowFor(['cctv1'], _utc(2026, 10, 30, 1, 0))?.title,
          '电视剧剧场');
    });

    test('display-name 归一化回退匹配（无 tvg-id 键）', () {
      // 频道名带空格与大小写差异仍命中。
      final hit = guide.nowFor([' cctv-1 综合'.toLowerCase()], _utc(2026, 10, 30, 0, 30));
      expect(hit, isNull, reason: '带连字符的名字不在匹配键里');
      final byName = guide.nowFor(['cctv-1综合'.replaceAll('-', '')], _utc(2026, 10, 30, 0, 30));
      expect(byName, isNull);
      // 正常归一化：去空格小写 'cctv-1综合' 不等，'cctv1综合' 才等 → 用名字原文。
      final nameHit = guide.nowFor(['CCTV-1 综合'.replaceAll(RegExp(r'\s+'), '').toLowerCase()], _utc(2026, 10, 30, 0, 30));
      expect(nameHit?.title, '朝闻天下', reason: 'display-name 归一化键应命中');
    });

    test('无匹配频道返回空', () {
      expect(guide.nowFor(['nope'], _utc(2026, 10, 30, 0, 30)), isNull);
    });

    test('非法 XML 返回空 guide', () {
      expect(parseEpgXml('<broken').isEmpty, isTrue);
    });
  });

  group('parseEpgBytes', () {
    test('gzip 自动解压', () {
      final gz = gzip.encode(utf8.encode(_xml));
      final guide = parseEpgBytes(Uint8List.fromList(gz));
      expect(guide.nowFor(['cctv1'], _utc(2026, 10, 30, 0, 30))?.title,
          '朝闻天下');
    });

    test('纯文本 UTF-8 直读', () {
      final guide = parseEpgBytes(Uint8List.fromList(utf8.encode(_xml)));
      expect(guide.isEmpty, isFalse);
    });
  });

  group('epgKeysFor', () {
    test('tvg-id 优先 + 频道名归一化', () {
      final keys = epgKeysFor(tvgId: 'cctv1', channelName: 'CCTV-1 综合');
      expect(keys.first, 'cctv1');
      expect(keys.last, 'cctv-1综合');
    });
  });
}

DateTime _utc(int y, int mo, int d, int h, int mi) =>
    DateTime.utc(y, mo, d, h, mi);
