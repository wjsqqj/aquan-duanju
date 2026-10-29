import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/live/live_parser.dart';
import 'package:aquan_duanju/core/live/live_probe.dart';
import 'package:aquan_duanju/core/sources/source_probe.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

void main() {
  group('TXT 格式', () {
    test('分组/多地址/线路名/ua referer 头', () {
      const txt = '''
// 注释行
央视,#genre#
CCTV1,http://a/1.m3u8#http://b/1.m3u8\$备用线路
CCTV2,http://c/2.m3u8|ua=okhttp/3.15&referer=http://r
卫视,#genre#
湖南卫视,http://d/hn
''';
      final groups = LiveParser.parse(txt);
      expect(groups.length, 2);
      expect(groups[0].name, '央视');
      expect(groups[0].channels[0].name, 'CCTV1');
      expect(groups[0].channels[0].urls.length, 2);
      expect(groups[0].channels[1].urls.single.headers['User-Agent'], 'okhttp/3.15');
      expect(groups[0].channels[1].urls.single.headers['Referer'], 'http://r');
      expect(groups[1].channels.single.name, '湖南卫视');
    });

    test('无分组时归入「未分组」', () {
      final groups = LiveParser.parse('新闻,http://a/news');
      expect(groups.single.name, '未分组');
      expect(groups.single.channels.single.name, '新闻');
    });
  });

  group('M3U 格式', () {
    test('#EXTINF 属性 + EXTVLCOPT 头 + 分组', () {
      const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" group-title="央视",CCTV-1 综合
#EXTVLCOPT:http-user-agent=okhttp/4
#EXTVLCOPT:http-referrer=https://live.example
http://a/cctv1.m3u8
#EXTINF:-1 group-title="地方",广东体育
http://a/gd.m3u8
''';
      final groups = LiveParser.parse(m3u);
      expect(groups.length, 2);
      expect(groups[0].name, '央视');
      final ch = groups[0].channels.single;
      expect(ch.name, 'CCTV-1 综合');
      expect(ch.urls.single.headers['User-Agent'], 'okhttp/4');
      expect(ch.urls.single.headers['Referer'], 'https://live.example');
      expect(groups[1].channels.single.name, '广东体育');
    });
  });

  group('JSON 格式', () {
    test('新格式 channels/urls', () {
      final json = jsonDecode('''
[{"group":"央视","channels":[{"name":"CCTV1","urls":["http://a/1.m3u8","http://b/1.m3u8"]}]}]
''');
      final groups = LiveParser.parseJson(json);
      expect(groups.single.name, '央视');
      expect(groups.single.channels.single.urls.length, 2);
    });

    test('旧格式 stations + url 单值(#分隔多地址)', () {
      final json = jsonDecode(
          '[{"group":"卫视","stations":[{"name":"东方卫视","url":"http://a#http://b"}]}]');
      final groups = LiveParser.parseJson(json);
      expect(groups.single.name, '卫视');
      expect(groups.single.channels.single.urls.length, 2);
    });

    test('lives 包裹形态', () {
      final json = jsonDecode(
          '{"lives":[{"group":"g","channels":[{"name":"c","urls":["http://a"]}]}]}');
      expect(LiveParser.parseJson(json).single.name, 'g');
    });
  });

  group('extractLives（TVBox 顶层 lives）', () {
    test('字符串/对象/多镜像/内嵌频道跳过', () {
      final lives = extractLives({
        'lives': [
          'http://plain/config.txt',
          {'name': '电视直播', 'type': 0, 'url': 'http://a/list.txt;http://b/list.txt'},
          {'name': '多地址', 'urls': ['http://x/1', 'http://x/2']},
          {'group': [
            {'name': '内嵌', 'urls': ['http://y']}
          ]},
        ],
      });
      expect(lives.length, 3);
      expect(lives[0].name, '直播源');
      expect(lives[1].url, 'http://a/list.txt');
      expect(lives[1].note, contains('镜像 1 个'));
      expect(lives[2].name, '多地址');
    });
  });

  group('LiveProbe', () {
    test('空频道直接失败', () async {
      final outcome = await LiveProbe.probeChannel(
          LiveChannel(name: 'x', urls: []));
      expect(outcome.state, ProbeState.failed);
    });
  });
}
