import 'package:aquan_duanju/core/reader/speech/speaker_splitter.dart';
import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

/// 多角色与编排层的接缝：音色变化必须断块，且每块的 job.voice 正确。
void main() {
  const narrator = TtsVoice(id: 'zh-A');
  const dialogue = TtsVoice(id: 'zh-B');
  const dialogueB = TtsVoice(id: 'zh-C');

  test('多角色：按角色换 voice，并在音色变化处断块', () async {
    final paragraphs = <String>['旁白开场。', '“第一句。”', '中间旁白。', '“第二句。”'];
    final units = splitSpeechUnits(paragraphs);
    final plan = SpeechRolePlan.fromVoices(
      const <TtsVoice>[narrator, dialogue, dialogueB],
      preferred: narrator,
    )!;
    final spans = <int, SpeechRoleSpan>{
      for (final span in SpeakerSplitter.split(units)) span.unit.index: span,
    };

    final engine = FakeTts();
    await TtsComposer().composeChapter(
      engine: engine,
      paragraphs: paragraphs,
      voice: plan.narrator,
      voiceFor: (unit) => plan.voiceFor(spans[unit.index]!),
      epoch: 1,
      units: units,
      isCurrent: (_) => true,
    );

    expect(engine.calls, 4, reason: '四种角色音色各不相同 → 必须切成 4 块');
    expect(engine.jobs[0].voice.id, plan.narrator.id);
    // 第一轮对话槽位=1 → 第二对话音色。
    expect(engine.jobs[1].voice.id, plan.dialogueSlotB!.id);
    expect(engine.jobs[2].voice.id, plan.narrator.id);
    // 第二轮对话槽位=0 → 主对话音色。
    expect(engine.jobs[3].voice.id, plan.dialogue.id);

    // 每块文本必须仍是章内连续切片（坐标契约不能因分块而破）。
    final chapterText = chapterPlainText(paragraphs);
    expect(chapterText.contains(engine.jobs[1].text), isTrue);
  });

  test('单音色（voiceFor=null）：仍按旧规则合并成一块', () async {
    final paragraphs = <String>['旁白开场。', '“第一句。”'];
    final engine = FakeTts();
    await TtsComposer().composeChapter(
      engine: engine,
      paragraphs: paragraphs,
      voice: narrator,
      epoch: 1,
      isCurrent: (_) => true,
    );
    expect(engine.calls, 1, reason: '没有多角色时应合并成一个块');
    expect(engine.jobs.single.voice.id, 'zh-A');
  });
}
