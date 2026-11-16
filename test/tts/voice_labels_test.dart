import 'package:aquan_duanju/core/tts/voice_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ttsVoiceLabelOf', () {
    test('常见 Edge 中文音色出中文名 + 性别', () {
      final String female = ttsVoiceLabelOf(
        id: 'zh-CN-XiaoxiaoNeural',
        displayName: 'Microsoft Xiaoxiao Online (Natural) - Chinese (Mainland)',
        locale: 'zh-CN',
      );
      expect(female, contains('晓晓'));
      expect(female, contains('女声'));

      final String male = ttsVoiceLabelOf(
        id: 'zh-CN-YunxiNeural',
        displayName: 'Microsoft Yunxi Online (Natural) - Chinese (Mainland)',
        locale: 'zh-CN',
      );
      expect(male, contains('云希'));
      expect(male, contains('男声'));
    });

    test('已知短名即使没有 displayName 也出中文', () {
      expect(ttsVoiceLabelOf(id: 'zh-CN-YunjianNeural'), contains('云健'));
    });

    test('未知音色：非空、去掉 Microsoft 前缀与地区尾巴', () {
      final String label = ttsVoiceLabelOf(
        id: 'xx-YY-FooNeural',
        displayName: 'Microsoft Foo Online (Natural) - Chinese (Mainland)',
        locale: 'xx-YY',
      );
      expect(label, isNotEmpty);
      expect(label, isNot(contains('Microsoft')));
      expect(label, isNot(contains('Mainland')));
      expect(label, contains('Foo'));
    });

    test('本机 Windows 语音转中文', () {
      final String label = ttsVoiceLabelOf(
        id: 'Microsoft Huihui Desktop',
        displayName: 'Microsoft Huihui Desktop - Chinese (Simplified)',
        locale: 'zh-CN',
      );
      expect(label, contains('慧慧'));
    });

    test('空 id 不崩，返回空串', () {
      expect(ttsVoiceLabelOf(id: ''), '');
    });
  });
}
