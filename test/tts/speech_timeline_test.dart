import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 两段三段：`甲句。乙句。` / `丙句。`
  List<SpeechUnit> threeUnits() => splitSpeechUnits(<String>['甲句。乙句。', '丙句。']);

  /// 每个 unit 给两个词点，词点覆盖 unit 的全部字符，时长依次 +1000ms。
  SpeechTimeline wordTimeline({SpeechGranularity g = SpeechGranularity.word}) {
    final units = threeUnits();
    final builder = SpeechTimelineBuilder(units: units, granularity: g);
    var t = 0;
    for (final u in units) {
      final half = (u.length / 2).ceil();
      builder
        ..addWord(
          SpeechPoint(
            startMs: t,
            endMs: t + 500,
            charStart: u.charStart,
            charEnd: u.charStart + half,
            unitIndex: u.index,
            text: u.text.substring(0, half),
          ),
        )
        ..addWord(
          SpeechPoint(
            startMs: t + 500,
            endMs: t + 1000,
            charStart: u.charStart + half,
            charEnd: u.charEnd,
            unitIndex: u.index,
            text: u.text.substring(half),
          ),
        );
      t += 1000;
    }
    builder.audioMs = t;
    return builder.build();
  }

  group('派生与查询', () {
    test('词表派生出句表与段表', () {
      final tl = wordTimeline();
      expect(tl.words.length, 6);
      expect(tl.sentences.length, 3);
      expect(tl.paragraphs.length, 2);
      // 句子区间必须等于 unit 区间（与阅读页同一坐标系）。
      final units = threeUnits();
      for (var i = 0; i < units.length; i++) {
        expect(tl.sentences[i].charStart, units[i].charStart);
        expect(tl.sentences[i].charEnd, units[i].charEnd);
      }
      // 段落区间覆盖该段所有句子。
      expect(tl.paragraphs[0].startMs, 0);
      expect(tl.paragraphs[0].endMs, 2000);
      expect(tl.paragraphs[1].startMs, 2000);
    });

    test('wordAt 二分：首点前为 null，命中返回自身', () {
      final tl = wordTimeline();
      expect(tl.wordAt(-1), isNull);
      expect(tl.wordAt(0)!.endMs, 500);
      expect(tl.wordAt(349)!.startMs, 0);
      expect(tl.wordAt(500)!.startMs, 500);
    });

    test('wordAt 落在点上取该点，落在间隙取上一个', () {
      final tl = wordTimeline();
      expect(tl.wordAt(499)!.startMs, 0);
      expect(tl.wordAt(500)!.startMs, 500);
      expect(tl.wordAt(2500)!.unitIndex, 2);
    });

    test('paragraphAt / startMsOfParagraph 往返一致', () {
      final tl = wordTimeline();
      expect(tl.paragraphAt(500, paragraphCount: 2), 0);
      expect(tl.paragraphAt(2000, paragraphCount: 2), 1);
      expect(tl.startMsOfParagraph(0, paragraphCount: 2), 0);
      expect(tl.startMsOfParagraph(1, paragraphCount: 2), 2000);
      expect(tl.paragraphAt(99999, paragraphCount: 2), 1);
    });

    test('clamp 到本地段落数，越界不抛', () {
      final tl = wordTimeline();
      expect(tl.paragraphAt(100, paragraphCount: 1), 0);
      expect(tl.paragraphAt(2000, paragraphCount: 99), 1);
    });

    test('缺某段精确点时按比例兜底，不返回 0', () {
      final units = threeUnits();
      final builder =
          SpeechTimelineBuilder(
            units: units,
            granularity: SpeechGranularity.word,
          )..addWord(
            SpeechPoint(
              startMs: 1000,
              endMs: 2000,
              charStart: units.last.charStart,
              charEnd: units.last.charEnd,
              unitIndex: units.last.index,
            ),
          );
      builder.audioMs = 2000;
      final tl = builder.build();
      expect(tl.paragraphs.length, 1);
      expect(tl.startMsOfParagraph(0, paragraphCount: 2), 0);
      expect(tl.startMsOfParagraph(1, paragraphCount: 2), 1000);
    });
  });

  group('精度位不可伪造', () {
    test('句级表查词返回 null', () {
      final tl = wordTimeline(g: SpeechGranularity.sentence);
      expect(tl.hasWordLevel, isFalse);
      expect(tl.wordAt(500), isNull);
      expect(tl.sentenceAt(500), isNotNull);
    });

    test('段级适配器查词与查句都返回 null', () {
      const adapter = ParagraphTimelineAdapter(AudioTimepoints(points: []));
      expect(adapter.granularity, SpeechGranularity.paragraph);
      expect(adapter.wordAt(100), isNull);
      expect(adapter.sentenceAt(100), isNull);
    });
  });

  group('近似字级展开', () {
    test('按时长均分且首尾对齐', () {
      const token = SpeechPoint(
        startMs: 100,
        endMs: 400,
        charStart: 10,
        charEnd: 13,
        unitIndex: 0,
        text: '这三个',
      );
      final chars = token.expandPerChar();
      expect(chars.length, 3);
      expect(chars.first.startMs, 100);
      expect(chars.last.endMs, 400);
      for (var i = 0; i < chars.length; i++) {
        expect(chars[i].charStart, 10 + i);
        expect(chars[i].charEnd, 11 + i);
        if (i > 0) expect(chars[i].startMs, chars[i - 1].endMs);
      }
    });

    test('单字符点原样返回', () {
      const one = SpeechPoint(
        startMs: 0,
        endMs: 100,
        charStart: 0,
        charEnd: 1,
        unitIndex: 0,
      );
      expect(one.expandPerChar(), hasLength(1));
    });
  });

  group('JSON 往返', () {
    test('字段逐项相等', () {
      final tl = wordTimeline();
      final back = SpeechTimeline.fromJson(tl.toJson());
      expect(back.granularity, tl.granularity);
      expect(back.audioMs, tl.audioMs);
      expect(back.words.length, tl.words.length);
      expect(back.sentences.length, tl.sentences.length);
      expect(back.paragraphs.length, tl.paragraphs.length);
      for (var i = 0; i < tl.words.length; i++) {
        expect(back.words[i].startMs, tl.words[i].startMs);
        expect(back.words[i].charStart, tl.words[i].charStart);
        expect(back.words[i].charEnd, tl.words[i].charEnd);
        expect(back.words[i].unitIndex, tl.words[i].unitIndex);
        expect(back.words[i].text, tl.words[i].text);
      }
      expect(back.paragraphs[1].paragraphIndex, 1);
    });

    test('坏数据回退到段落级且不抛', () {
      final back = SpeechTimeline.fromJson(<String, dynamic>{
        'granularity': 'nonsense',
        'words': <dynamic>[<String, dynamic>{}],
      });
      expect(back.granularity, SpeechGranularity.paragraph);
      expect(back.words.length, 1);
      expect(back.words.first.startMs, 0);
    });
  });

  group('音轨段落级适配器行为不变', () {
    test('有 para 时与 AudioTimepoints 逐项相等', () {
      const points = AudioTimepoints(
        points: <AudioTimepoint>[
          AudioTimepoint(startMs: 0, endMs: 4000, para: 0),
          AudioTimepoint(startMs: 4000, endMs: 9000, para: 1),
          AudioTimepoint(startMs: 9000, endMs: 15000, para: 2),
        ],
      );
      const adapter = ParagraphTimelineAdapter(points);
      for (var ms = -100; ms < 20000; ms += 337) {
        expect(
          adapter.paragraphAt(ms, paragraphCount: 3),
          points.paragraphAt(ms, paragraphCount: 3),
          reason: 'ms=$ms',
        );
      }
      for (var p = 0; p < 3; p++) {
        expect(
          adapter.startMsOfParagraph(p, paragraphCount: 3),
          points.startMsOfParagraph(p, paragraphCount: 3),
        );
      }
      expect(
        adapter.offsetMs(paragraphIndex: 1, ratio: 0.5),
        points.offsetMs(paragraphIndex: 1, ratio: 0.5),
      );
    });

    test('无 para（上游切段不一致）时走比例兜底，同样相等', () {
      const points = AudioTimepoints(
        points: <AudioTimepoint>[
          AudioTimepoint(startMs: 0, endMs: 3000, para: -1),
          AudioTimepoint(startMs: 3000, endMs: 8000, para: -1),
          AudioTimepoint(startMs: 8000, endMs: 20000, para: -1),
        ],
      );
      const adapter = ParagraphTimelineAdapter(points);
      for (var ms = 0; ms < 20000; ms += 500) {
        expect(
          adapter.paragraphAt(ms, paragraphCount: 5),
          points.paragraphAt(ms, paragraphCount: 5),
          reason: 'ms=$ms',
        );
      }
    });
  });
}
