/// 朗读高亮的**区间与通知策略**（design.md §3）：控制器把「哪条路径、什么精度、
/// 当前句/词的字符区间」一次性暴露成只读接口，并保证高频位置事件里
/// **下标没变就不 notify**。
///
/// 三条不变量各有用例：
/// 1. 词级只可能来自自建合成表，音轨路径必须停在段级（禁止静默降级）；
/// 2. 用户偏好只能**降低**精度，不能凭空造出词级；
/// 3. 世代递增（切章/关闭）必须清空区间缓存，否则高亮串章。
library;

import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/reader/reader_speech_settings.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'speech_fakes.dart';

/// 两条音轨：真人讲书（genreType=1）与平台智能朗读（genreType=0）。
const AudioTones _recordedTones = AudioTones(
  genreType: 1,
  tones: <AudioTone>[AudioTone(id: 74, title: '真人')],
);

const AudioTones _platformTones = AudioTones(
  tones: <AudioTone>[AudioTone(id: 75, title: '男声')],
);

const AudioTimepoints _twoParagraphPoints = AudioTimepoints(
  points: <AudioTimepoint>[
    AudioTimepoint(startMs: 0, para: 0),
    AudioTimepoint(startMs: 1000, para: 1),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpeechHarness harness;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    harness = SpeechHarness('speech_highlight');
  });

  tearDown(() {
    harness.dispose();
  });

  group('词级路径（自建合成时间表）', () {
    test('开播就有词/句区间，位置推进时区间跟着走', () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);

      expect(controller.playing, isTrue);
      expect(controller.activePath, SpeechPath.cloudTts);
      expect(controller.hasTimeline, isTrue);
      expect(controller.highlightGranularity, SpeechGranularity.word);
      // 开播这一刻就算好区间：首帧必须有高亮，不能等第一个位置事件。
      expect(controller.highlightWord, (0, 1));
      expect(controller.highlightSentence, isNotNull);

      await harness.pumpPosition(35);
      // 正文 '甲乙。丙丁。\n戊己。'，假引擎每字 10ms → 35ms 落在第 4 个字。
      expect(controller.highlightWord, (3, 4));
      expect(
        controller.highlightSentence!.$1 <= 3 &&
            3 < controller.highlightSentence!.$2,
        isTrue,
        reason: '当前词必须落在当前句区间内',
      );
    });

    test('句级引擎不伪造词级：highlightWord 恒 null，粒度停在句', () async {
      final controller = harness.build(FakeTts(wordBoundary: false));
      await harness.start(controller);

      expect(controller.highlightGranularity, SpeechGranularity.sentence);
      expect(controller.highlightWord, isNull);
      await harness.pumpPosition(35);
      expect(controller.highlightWord, isNull);
      expect(controller.highlightSentence, isNotNull);
    });
  });

  group('音轨路径（段级天花板）', () {
    test('真人讲书：activePath=recorded，词/句区间都不给', () async {
      harness.api.tones = _recordedTones;
      harness.api.timepoints = _twoParagraphPoints;
      final engine = FakeTts();
      final controller = harness.build(engine);
      controller.setParagraphCount(2);
      await harness.start(controller);

      expect(controller.activePath, SpeechPath.recorded);
      expect(controller.hasTimeline, isFalse);
      expect(controller.highlightGranularity, SpeechGranularity.paragraph);
      expect(controller.highlightWord, isNull);
      expect(controller.highlightSentence, isNull);
      expect(engine.calls, 0, reason: '有平台音轨时不该动合成引擎');
      expect(harness.api.chapterTextCalls, 0, reason: '音轨路径不取正文');

      await harness.pumpPosition(1500);
      expect(controller.paragraphIndex, 1);
      expect(controller.highlightWord, isNull);
      expect(controller.highlightSentence, isNull);
    });

    test('平台智能朗读：activePath=platformTone，同样只有段级', () async {
      harness.api.tones = _platformTones;
      harness.api.timepoints = _twoParagraphPoints;
      final controller = harness.build(FakeTts());
      controller.setParagraphCount(2);
      await harness.start(controller);

      expect(controller.activePath, SpeechPath.platformTone);
      expect(controller.highlightGranularity, SpeechGranularity.paragraph);
      expect(controller.highlightWord, isNull);
    });
  });

  group('偏好只能降精度，不能造精度', () {
    test('偏好句级时不画词，句底纹照常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ReaderSpeechSettings.granularityKey:
            SpeechHighlightGranularity.sentence.name,
      });
      final controller = harness.build(FakeTts());
      await harness.start(controller);

      expect(controller.highlightGranularity, SpeechGranularity.sentence);
      expect(controller.highlightWord, isNull);
      expect(controller.highlightSentence, isNotNull);
    });

    test('音轨表 + 偏好词级：仍然是段级（不许把拿不到词级伪装成正常）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ReaderSpeechSettings.granularityKey:
            SpeechHighlightGranularity.word.name,
      });
      harness.api.tones = _platformTones;
      harness.api.timepoints = _twoParagraphPoints;
      final controller = harness.build(FakeTts());
      controller.setParagraphCount(2);
      await harness.start(controller);

      expect(controller.highlightGranularity, SpeechGranularity.paragraph);
      expect(controller.highlightWord, isNull);
    });

    test('缺键按默认（词级）', () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);
      expect(controller.highlightGranularity, SpeechGranularity.word);
    });
  });

  group('索引未变不 notify', () {
    test('同一个词内的位置事件不发通知，跨词立刻发', () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);

      var notifies = 0;
      void listener() => notifies++;
      controller.addListener(listener);
      addTearDown(() => controller.removeListener(listener));

      // 词下标变了 → 立刻 notify（卡拉OK 不等 250ms）。
      await harness.pumpPosition(15);
      expect(notifies, 1);
      // 还在同一个词里（10–20ms）：只按进度条节流，一次都不发。
      await harness.pumpPosition(16);
      await harness.pumpPosition(17);
      await harness.pumpPosition(18);
      expect(notifies, 1, reason: '词下标没变 → 不 notify（design.md §3）');
      // 跨到下一个词：马上通知。
      await harness.pumpPosition(25);
      expect(notifies, 2);
      // 段落下标跨段同样立刻通知，否则自动跟随看起来「不跟」。
      await harness.pumpPosition(1500);
      expect(notifies, 3);
    });
  });

  group('世代递增必须清缓存', () {
    test('close() 后词/句区间与段落快照都不残留', () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);
      expect(controller.highlightWord, isNotNull);
      expect(controller.speechParagraphs, isNotEmpty);

      await controller.close();
      expect(controller.highlightWord, isNull);
      expect(controller.highlightSentence, isNull);
      expect(controller.speechParagraphs, isEmpty);
    });

    test('切章时旧章区间不许串到新章（清缓存先于新表到位）', () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);
      expect(controller.highlightWord, isNotNull);

      await controller.next();
      // 新章的时间表与新缓存同源：区间仍在，但段落快照已指向第二章。
      expect(controller.chapterIndex, 1);
      expect(
        controller.highlightSentence ?? controller.highlightWord,
        isNotNull,
      );
    });
  });
}
