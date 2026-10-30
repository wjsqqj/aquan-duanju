/// 「我的 → 设置 → 听书」那七个键（design.md §7）：读写、默认值，以及
/// **`listen.tts.proxy` 绝不进备份**这条敏感项约束。
///
/// 备份的排除方式不是「加一张黑名单」，而是 `SettingsStore.exportBackup()` 里那份
/// **写死的字面量名单**：不在名单上的键天然不出门（`voice.apiKey` 就是这么处理的）。
/// 所以这里断言的是「名单里没有 listen.*」，而不是「我们记得排除了代理」。
library;

import 'package:aquan_duanju/core/reader/reader_listen_settings.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/reader/reader_speech_settings.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late ReaderListenSettings tts;
  late ReaderSpeechSettings display;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    tts = ReaderListenSettings(prefs);
    display = ReaderSpeechSettings(prefs);
  });

  group('键的字面值只有一处定义', () {
    test('听书四键沿用控制器里的常量，显示三键沿用 ReaderSpeechSettings', () {
      // 控制器 `_loadPrefs` 读的就是这些常量：设置页写别的键等于白写。
      expect(ReaderListenSettings.ttsEnabledKey, 'listen.tts.enabled');
      expect(ReaderListenSettings.ttsEnabledKey,
          ReaderSpeechController.ttsEnabledKey);
      expect(ReaderListenSettings.ttsEngineKey, 'listen.tts.engine');
      expect(
        ReaderListenSettings.ttsEngineKey,
        ReaderSpeechController.ttsEngineKey,
      );
      expect(ReaderListenSettings.ttsVoiceKey, 'listen.tts.voice');
      expect(
        ReaderListenSettings.ttsVoiceKey,
        ReaderSpeechController.ttsVoiceKey,
      );
      expect(ReaderListenSettings.ttsProxyKey, 'listen.tts.proxy');
      expect(
        ReaderListenSettings.ttsProxyKey,
        ReaderSpeechController.ttsProxyKey,
      );

      expect(ReaderSpeechSettings.granularityKey, 'listen.granularity');
      expect(ReaderSpeechSettings.highlightStyleKey, 'listen.highlightStyle');
      expect(ReaderSpeechSettings.highlightColorKey, 'listen.highlightColor');
    });
  });

  group('缺键按默认值', () {
    test('自建朗读默认开、引擎 edge、音色/代理空、词级 + 底色 + 跟随主题', () {
      expect(tts.ttsEnabled, isTrue);
      expect(tts.ttsEngineId, kDefaultTtsEngineId);
      expect(tts.ttsVoiceId, '');
      expect(tts.ttsProxy, '');
      expect(display.granularity, SpeechHighlightGranularity.word);
      expect(display.style, SpeechHighlightStyle.highlight);
      expect(display.colorArgb, kSpeechColorFollowTheme);
    });

    test('脏值回默认，不让设置页因为坏数据白屏', () {
      prefs.setString(ReaderSpeechSettings.granularityKey, 'no-such-granularity');
      prefs.setString(ReaderSpeechSettings.highlightStyleKey, 'no-such-style');
      expect(display.granularity, SpeechHighlightGranularity.word);
      expect(display.style, SpeechHighlightStyle.highlight);
    });
  });

  group('写入后可读回', () {
    test('七个键逐项往返', () async {
      await tts.setTtsEnabled(false);
      await tts.setTtsEngineId('edge');
      await tts.setTtsVoiceId('zh-CN-XiaoxiaoNeural');
      await tts.setTtsProxy('http://127.0.0.1:10809');
      await display.setGranularity(SpeechHighlightGranularity.sentence);
      await display.setStyle(SpeechHighlightStyle.squiggly);
      await display.setColorArgb(0xFFF7C948);

      // 重新包一层：证明真值在 prefs 里，不在这次的内存对象里。
      final again = ReaderListenSettings(prefs);
      final againDisplay = ReaderSpeechSettings(prefs);
      expect(again.ttsEnabled, isFalse);
      expect(again.ttsEngineId, 'edge');
      expect(again.ttsVoiceId, 'zh-CN-XiaoxiaoNeural');
      expect(again.ttsProxy, 'http://127.0.0.1:10809');
      expect(againDisplay.granularity, SpeechHighlightGranularity.sentence);
      expect(againDisplay.style, SpeechHighlightStyle.squiggly);
      expect(againDisplay.colorArgb, 0xFFF7C948);
    });

    test('空值/跟随主题都删键，不留死值', () async {
      await tts.setTtsVoiceId('zh-CN-YunxiNeural');
      await tts.setTtsProxy('http://127.0.0.1:7890');
      await display.setColorArgb(0xFF64B5F6);
      await tts.setTtsVoiceId('');
      await tts.setTtsProxy('');
      await display.setColorArgb(kSpeechColorFollowTheme);

      expect(prefs.containsKey(ReaderListenSettings.ttsVoiceKey), isFalse);
      expect(prefs.containsKey(ReaderListenSettings.ttsProxyKey), isFalse);
      expect(prefs.containsKey(ReaderSpeechSettings.highlightColorKey), isFalse);
      expect(tts.ttsVoiceId, '');
      expect(tts.ttsProxy, '');
      expect(display.colorArgb, kSpeechColorFollowTheme);
    });

    test('高亮色候选里第 0 项就是跟随主题', () {
      expect(kSpeechColorPresets.containsKey(kSpeechColorFollowTheme), isTrue);
      expect(kSpeechColorPresets[kSpeechColorFollowTheme], '跟随主题');
    });
  });

  group('敏感项不进备份', () {
    test('exportBackup 的白名单里没有任何 listen.*，也没有 voice.apiKey', () {
      final backup = SettingsStore(prefs).exportBackup();

      expect(
        backup.keys.where((k) => k.startsWith('listen.')),
        isEmpty,
        reason: '听书设置是**本机**设置，不跨设备携带',
      );
      expect(
        backup.containsKey(ReaderListenSettings.ttsProxyKey),
        isFalse,
        reason: '代理地址可能带凭据：只写 prefs，不进备份（与 voice.apiKey 同一处理）',
      );
      expect(backup.containsKey('voice.apiKey'), isFalse);
    });

    test('写满七个键之后再导出，备份里仍然一个 listen.* 都没有', () async {
      await tts.setTtsEnabled(false);
      await tts.setTtsEngineId('edge');
      await tts.setTtsVoiceId('zh-CN-XiaoxiaoNeural');
      await tts.setTtsProxy('http://user:pass@127.0.0.1:10809');
      await display.setGranularity(SpeechHighlightGranularity.word);
      await display.setStyle(SpeechHighlightStyle.outline);
      await display.setColorArgb(0xFFF28B82);

      final backup = SettingsStore(prefs).exportBackup();
      final json = backup.toString();

      expect(backup.keys.where((k) => k.startsWith('listen.')), isEmpty);
      expect(
        json.contains('10809'),
        isFalse,
        reason: '连代理地址的字样都不该出现在备份内容里',
      );
      expect(
        prefs.getString(ReaderListenSettings.ttsProxyKey),
        'http://user:pass@127.0.0.1:10809',
        reason: '本机照样读得到，只是不出门',
      );
    });
  });
}
