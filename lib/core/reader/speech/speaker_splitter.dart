/// 多角色朗读：用**引号栈规则**把每个朗读单元分成「旁白 / 对话」，并给对话分配
/// 轮次槽位（0/1 交替），从而在不接任何模型的前提下换音色朗读。
///
/// 已知坑（`research/legado-with-MD3.md`）：引号栈若跨章持久化，遇到未闭合引号
/// 会「永久卡死在对话态」，整本书都用错音色。这里三条防线：
/// 1. **章内状态**：栈只活在单次 [split] 调用里，章末自然丢弃（没有跨章副作用）；
/// 2. **栈深上限** `maxQuoteDepth`：超过就不再加深（宁可判成旁白，也不死锁）；
/// 3. **只认中文引号**：`“”「」『』`。ASCII 双引号在中文正文里既可能是引号也可能
///    是英寸/代码片段，误判代价比漏判大，所以不参与配对。
library;

import '../../tts/tts_models.dart';
import 'speech_unit.dart';

/// 朗读角色。
enum SpeechRole {
  /// 旁白/叙述。
  narration,

  /// 角色对白（引号内）。
  dialogue,
}

/// 一个朗读单元的角色归属。
class SpeechRoleSpan {
  const SpeechRoleSpan({
    required this.unit,
    required this.role,
    required this.slot,
  });

  final SpeechUnit unit;
  final SpeechRole role;

  /// 对话轮次槽位：0 / 1 交替，用于给两个不同角色分配不同音色；
  /// 旁白恒为 0。
  final int slot;
}

/// 引号栈规则的角色切分。纯函数、无状态（章末不残留）。
class SpeakerSplitter {
  const SpeakerSplitter._();

  /// 默认栈深上限：正常小说嵌套不会超过 2 层，4 已经很宽松。
  static const int defaultMaxQuoteDepth = 4;

  static const Set<String> openers = <String>{'“', '「', '『'};
  static const Set<String> closers = <String>{'”', '」', '』'};

  /// 把一章的单元切成带角色的序列。
  ///
  /// [maxQuoteDepth] <= 0 时回退到默认值。
  static List<SpeechRoleSpan> split(
    List<SpeechUnit> units, {
    int maxQuoteDepth = defaultMaxQuoteDepth,
  }) {
    final limit = maxQuoteDepth > 0 ? maxQuoteDepth : defaultMaxQuoteDepth;
    // 栈深只在本章内累积：函数返回即丢弃（防线 1）。
    var depth = 0;
    var slot = 0;
    var inDialogueTurn = false;
    final out = <SpeechRoleSpan>[];

    for (final unit in units) {
      final startDepth = depth;
      // 扫一遍本单元的字符：先记「进来时是否在引号内」，再更新栈。
      var sawQuote = false;
      for (final ch in unit.text.split('')) {
        if (openers.contains(ch)) {
          sawQuote = true;
          if (depth < limit) depth++;
        } else if (closers.contains(ch)) {
          sawQuote = true;
          if (depth > 0) depth--;
        }
      }

      final isDialogue = startDepth > 0 || sawQuote;
      if (isDialogue) {
        if (!inDialogueTurn) {
          // 新的一轮对话：与上一轮换一个槽位，让两个角色声音不同。
          slot = (slot + 1) % 2;
          inDialogueTurn = true;
        }
      } else {
        // 旁白只结束当前对话轮次；**不重置 slot**，否则每一轮对话都会拿回同一个
        // 槽位，「两个角色」就退化成「一个角色」了。
        inDialogueTurn = false;
      }

      out.add(
        SpeechRoleSpan(
          unit: unit,
          role: isDialogue ? SpeechRole.dialogue : SpeechRole.narration,
          slot: isDialogue ? slot : 0,
        ),
      );
    }
    return out;
  }
}

/// 角色 → 音色的映射计划。旁白必须有一个，对话最多两个（0/1 槽）。
class SpeechRolePlan {
  const SpeechRolePlan({
    required this.narrator,
    required this.dialogue,
    this.dialogueSlotB,
  });

  final TtsVoice narrator;
  final TtsVoice dialogue;
  final TtsVoice? dialogueSlotB;

  /// 计划签名：进缓存键。**顺序固定**（narrator/dialogue/B），
  /// 否则同一套音色会算出两个键、缓存失效。
  String get signature => <String>[
    narrator.id,
    dialogue.id,
    dialogueSlotB?.id ?? '',
  ].join('+');

  /// 这套计划实际用到的音色 id（去重、排序）——缓存键与诊断都用它。
  List<String> get voiceIds {
    final ids = <String>{
      narrator.id,
      dialogue.id,
      if (dialogueSlotB != null) dialogueSlotB!.id,
    }.toList()..sort();
    return ids;
  }

  TtsVoice voiceFor(SpeechRoleSpan span) {
    if (span.role == SpeechRole.narration) return narrator;
    final b = dialogueSlotB;
    if (span.slot == 1 && b != null) return b;
    return dialogue;
  }

  /// 从引擎可用音色里挑出最多三个**不同**的音色：
  /// 旁白 = 用户选的（[preferred]），对话优先用 [dialoguePreferences] 里的 id，
  /// 都不够时按列表顺序取不同的。只有一个音色时退化为单角色（不报错）。
  static SpeechRolePlan? fromVoices(
    List<TtsVoice> voices, {
    TtsVoice? preferred,
    List<String> dialoguePreferences = const <String>[],
  }) {
    if (voices.isEmpty) return null;

    TtsVoice firstNotIn(Set<String> exclude) {
      for (final v in voices) {
        if (!exclude.contains(v.id)) return v;
      }
      return voices.first;
    }

    final narrator = preferred ?? voices.first;
    final taken = <String>{narrator.id};

    TtsVoice? dialogue;
    for (final id in dialoguePreferences) {
      if (id == narrator.id) continue;
      for (final v in voices) {
        if (v.id == id) {
          dialogue = v;
          break;
        }
      }
      if (dialogue != null) break;
    }
    dialogue ??= firstNotIn(taken);
    taken.add(dialogue.id);

    // 第三槽位：**只有真的存在第三个不同音色**才给。
    // 否则（只有两个音色）就让 slotB 为 null，绝不能把旁白音色再拿回来冒充角色二。
    TtsVoice? slotB;
    for (final v in voices) {
      if (!taken.contains(v.id)) {
        slotB = v;
        break;
      }
    }
    return SpeechRolePlan(
      narrator: narrator,
      dialogue: dialogue,
      dialogueSlotB: slotB,
    );
  }
}
