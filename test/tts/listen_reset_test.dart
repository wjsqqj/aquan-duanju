import 'package:aquan_duanju/core/reader/reader_listen_settings.dart';
import 'package:aquan_duanju/core/reader/speech/chapter_gap.dart';
import 'package:aquan_duanju/core/reader/speech/sleep_timer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 恢复听书默认：按前缀清 `listen.*`，绝不碰进度与非听书偏好。
void main() {
  test('只删 listen.*；别的键（含进度）原样保留', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'listen.tts.enabled': false,
      'listen.speed': 1.7,
      'listen.speed.7001': 1.9,
      'listen.tts.sources': '[{"id":"x","url":"http://h?text={text}"}]',
      'listen.tts.proxy': '127.0.0.1:7890',
      'listen.chapterGapMs': 1500,
      // 非听书键：阅读设置与两张进度表都不该被清。
      'reader.fontSize': 21,
      'reading.progress': '{"x":1}',
    });
    final prefs = await SharedPreferences.getInstance();
    final removed = await ReaderListenSettings(prefs).resetAll();

    expect(removed, 6);
    final left = prefs.getKeys();
    expect(left.any((key) => key.startsWith('listen.')), isFalse);
    expect(left, containsAll(<String>['reader.fontSize', 'reading.progress']));
  });

  test('默认值本来就等于出厂时：removed 为 0，不报错', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    expect(await ReaderListenSettings(prefs).resetAll(), 0);
  });

  test('resetAll 后所有听书 getter 都回到默认', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'listen.tts.enabled': false,
      'listen.roles.enabled': true,
      'listen.roles.voices': '["zh-A"]',
      'listen.trim.silence': false,
      'listen.sleep.fadeOut': false,
      'listen.chapterGapMs': 3000,
      'listen.prefetch': false,
      'listen.sleepMode': 'minutes',
      'listen.sleepMinutes': 90,
    });
    final prefs = await SharedPreferences.getInstance();
    await ReaderListenSettings(prefs).resetAll();
    final settings = ReaderListenSettings(prefs);

    expect(settings.ttsEnabled, isTrue);
    expect(settings.rolesEnabled, isFalse);
    expect(settings.roleVoices, isEmpty);
    expect(settings.trimSilenceEnabled, isTrue);
    expect(settings.sleepFadeOutEnabled, isTrue);
    expect(settings.chapterGapMs, kDefaultChapterGapMs);
    expect(settings.prefetchEnabled, isTrue);
    expect(settings.sleepMode, isNot(SleepMode.minutes));
    expect(settings.ttsSourceJson, isEmpty);
  });
}
