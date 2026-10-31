import 'dart:convert';

import 'package:aquan_duanju/core/tts/http/http_tts_source.dart';
import 'package:aquan_duanju/core/tts/http/tts_source_presets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 官方云源预设：模板必须都能被解析，XML 转义必须正确，往返不丢字段。
void main() {
  test('每个预设都是合法配置（tryParse 不返回 null）', () {
    expect(kTtsSourcePresets, isNotEmpty);
    for (final preset in kTtsSourcePresets) {
      final parsed = HttpTtsSource.tryParse(preset.json);
      expect(parsed, isNotNull, reason: '预设 ${preset.key} 解析失败');
      expect(parsed!.id, isNotEmpty);
      expect(preset.hint, isNotEmpty, reason: '预设必须告诉用户改什么');
    }
  });

  test('预设 key 唯一，且能按 key 反查', () {
    final keys = kTtsSourcePresets.map((p) => p.key).toList();
    expect(keys.toSet().length, keys.length);
    for (final key in keys) {
      expect(ttsSourcePresetByKey(key)?.key, key);
    }
    expect(ttsSourcePresetByKey('不存在'), isNull);
  });

  test('Azure 预设：bodyEscape=xml，SSML 里的特殊字符被转义', () {
    final source = HttpTtsSource.tryParse(ttsSourcePresetByKey('azure')!.json)!;
    expect(source.bodyEscape, HttpTtsBodyEscape.xml);
    expect(source.isPost, isTrue);

    final body = source.buildBody(
      text: 'A&B <测试> "引号" 它\'s',
      voice: 'zh-CN-XiaoxiaoNeural',
    );
    // 文本里的裸字符必须全部实体化（否则 SSML 直接变非法 XML）。
    expect(body, contains('A&amp;B &lt;测试&gt;'));
    expect(body, contains('&quot;引号&quot;'));
    expect(body, contains('它&apos;s'));
    expect(body, isNot(contains('A&B')), reason: '裸 & 不得残留');
    expect(body, contains("<voice name='zh-CN-XiaoxiaoNeural'>"));
  });

  test('火山预设：jsonBase64 + data 字段', () {
    final source = HttpTtsSource.tryParse(ttsSourcePresetByKey('volcengine')!.json)!;
    expect(source.mode, HttpTtsResponseMode.jsonBase64);
    expect(source.audioField, 'data');
    expect(source.bodyEscape, HttpTtsBodyEscape.json);
    // body 里的 text 用 JSON 转义：双引号必须变成 \"
    final body = source.buildBody(text: '他说"你好"', voice: 'v1');
    expect(body, contains(r'\"你好\"'));
    // 整个 body 仍应是合法 JSON
    expect(() => jsonDecode(body), returnsNormally);
  });

  test('{text} 允许只出现在 body 里（SSML 端点），但两者都没有就拒绝', () {
    final onlyBody = HttpTtsSource.tryParse(<String, dynamic>{
      'id': 'x',
      'url': 'https://example.com/tts',
      'method': 'POST',
      'body': '<speak>{text}</speak>',
      'bodyEscape': 'xml',
    });
    expect(onlyBody, isNotNull);

    final none = HttpTtsSource.tryParse(<String, dynamic>{
      'id': 'y',
      'url': 'https://example.com/tts',
      'method': 'POST',
      'body': '<speak>没有占位符</speak>',
    });
    expect(none, isNull);
  });

  test('toJson 往返保留 bodyEscape（非默认值才写）', () {
    final azure = HttpTtsSource.tryParse(ttsSourcePresetByKey('azure')!.json)!;
    expect(azure.toJson()['bodyEscape'], 'xml');
    final back = HttpTtsSource.tryParse(azure.toJson())!;
    expect(back.bodyEscape, HttpTtsBodyEscape.xml);

    final local = HttpTtsSource.tryParse(ttsSourcePresetByKey('local-tts-server')!.json)!;
    expect(local.toJson().containsKey('bodyEscape'), isFalse, reason: '默认值不写，保持 JSON 干净');
    expect(HttpTtsSource.tryParse(local.toJson())!.bodyEscape, HttpTtsBodyEscape.json);
  });
}
