import 'package:aquan_duanju/core/reader/speech/speaker_splitter.dart';
import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 多角色规则（无模型）：引号栈判旁白/对话 + 对话轮次槽位 + 音色计划挑选。
void main() {
  List<SpeechUnit> unitsOf(List<String> paragraphs) =>
      splitSpeechUnits(paragraphs);

  List<SpeechRole> rolesOf(List<SpeechUnit> units) =>
      SpeakerSplitter.split(units).map((s) => s.role).toList();

  List<int> slotsOf(List<SpeechUnit> units) =>
      SpeakerSplitter.split(units).map((s) => s.slot).toList();

  group('引号栈判角色', () {
    test('引号内是对话，引号外是旁白', () {
      final units = unitsOf(<String>['他抬起头。', '“谁在那儿？”', '屋里没人应答。']);
      expect(rolesOf(units), <SpeechRole>[
        SpeechRole.narration,
        SpeechRole.dialogue,
        SpeechRole.narration,
      ]);
    });

    test('跨单元未闭合引号：后续单元延续对话', () {
      // 第一段开了引号没收，第二段应被判为对话（栈在章内延续）。
      final units = unitsOf(<String>['他说：“我走了。', '明天见。”', '然后关上门。']);
      expect(rolesOf(units), <SpeechRole>[
        SpeechRole.dialogue,
        SpeechRole.dialogue,
        SpeechRole.narration,
      ]);
    });

    test('章末不残留：下一章从旁白重新开始（防「引号栈永久卡死」）', () {
      final first = unitsOf(<String>['“这句话没闭合。']);
      expect(rolesOf(first), <SpeechRole>[SpeechRole.dialogue]);

      // 第二次调用是另一章：绝不能继承上一章的未闭合状态。
      final second = unitsOf(<String>['新的章节开头。']);
      expect(rolesOf(second), <SpeechRole>[SpeechRole.narration]);
    });

    test('栈深上限：限制深度且收尾后能回到旁白（不死锁）', () {
      // 连续 8 个开引号 → 深度被 clamp 到 2；随后 6 个闭合符号能把栈清空。
      final units = unitsOf(<String>[
        '“「『“「『“「开头。',
        '继续。',
        '”」』”」』”」收尾。',
        '真正的旁白。',
      ]);
      final spans = SpeakerSplitter.split(units, maxQuoteDepth: 2);
      expect(spans.first.role, SpeechRole.dialogue);
      // 关键：没有死锁在对话态 —— 引号收完后必须能回到旁白。
      expect(spans.last.role, SpeechRole.narration);
    });

    test('maxQuoteDepth <= 0 回退默认值（不抛）', () {
      final units = unitsOf(<String>['“对话。”']);
      expect(
        SpeakerSplitter.split(units, maxQuoteDepth: 0).first.role,
        SpeechRole.dialogue,
      );
    });
  });

  group('对话轮次槽位', () {
    test('两轮对话交替槽位（旁白只结束轮次、不重置槽位）', () {
      final units = unitsOf(<String>['旁白开场。', '“第一句。”', '中间旁白。', '“第二句。”']);
      // 对话轮 1 → slot 1；轮 2 → slot 0（交替才有两个角色的感觉）。
      expect(slotsOf(units), <int>[0, 1, 0, 0]);
    });

    test('同一轮里的连续对话单元共用一个槽位', () {
      final units = unitsOf(<String>['“第一段。', '第二段。”', '旁白。']);
      expect(slotsOf(units), <int>[1, 1, 0]);
    });
  });

  group('音色计划', () {
    const a = TtsVoice(id: 'zh-A');
    const b = TtsVoice(id: 'zh-B');
    const c = TtsVoice(id: 'zh-C');

    test('三个音色：旁白/对话/第二对话各不相同', () {
      final plan = SpeechRolePlan.fromVoices(<TtsVoice>[a, b, c], preferred: a);
      expect(plan, isNotNull);
      expect(plan!.narrator.id, 'zh-A');
      expect(plan.dialogue.id, isNot('zh-A'));
      expect(plan.dialogueSlotB?.id, isNotNull);
      expect(plan.dialogueSlotB!.id, isNot(plan.dialogue.id));
    });

    test('两个音色：只给旁白 + 对话，第三槽位为 null（不非法重用）', () {
      final plan = SpeechRolePlan.fromVoices(<TtsVoice>[a, b], preferred: a);
      expect(plan!.dialogue.id, 'zh-B');
      expect(plan.dialogueSlotB, isNull);
    });

    test('只有一个音色：退化单角色，不报错', () {
      final plan = SpeechRolePlan.fromVoices(<TtsVoice>[a], preferred: a);
      expect(plan!.narrator.id, 'zh-A');
      expect(plan.dialogue.id, 'zh-A');
      expect(plan.dialogueSlotB, isNull);
    });

    test('对话音色偏好优先，且不会与旁白撞车', () {
      final plan = SpeechRolePlan.fromVoices(
        <TtsVoice>[a, b, c],
        preferred: a,
        dialoguePreferences: <String>['zh-C', 'zh-A'],
      );
      expect(plan!.dialogue.id, 'zh-C', reason: '偏好里第一个合法音色生效');
    });

    test('签名稳定且含全部音色（缓存键用它区分多角色产物）', () {
      final plan = SpeechRolePlan.fromVoices(<TtsVoice>[a, b, c], preferred: a);
      expect(plan!.signature, '${plan.narrator.id}+${plan.dialogue.id}+${plan.dialogueSlotB!.id}');
      // voiceIds 去重排序：换一个顺序同一套音色必须得到同一个键。
      expect(plan.voiceIds, <String>['zh-A', 'zh-B', 'zh-C']);
    });

    test('voiceFor 按角色与槽位取音色', () {
      final plan = SpeechRolePlan.fromVoices(<TtsVoice>[a, b, c], preferred: a)!;
      // 两轮对话之间必须有旁白，槽位才会翻转（连续对话属于同一轮）。
      final units = unitsOf(<String>['旁白。', '“对话一。”', '中间旁白。', '“对话二。”']);
      final spans = SpeakerSplitter.split(units);
      expect(spans[0].role, SpeechRole.narration);
      expect(plan.voiceFor(spans[0]).id, plan.narrator.id);
      // 第一轮对话 → 槽位 1 → 第二对话音色。
      expect(spans[1].slot, 1);
      expect(plan.voiceFor(spans[1]).id, plan.dialogueSlotB!.id);
      // 第二轮对话 → 槽位 0 → 主对话音色。
      expect(spans[3].slot, 0);
      expect(plan.voiceFor(spans[3]).id, plan.dialogue.id);
    });
  });
}
