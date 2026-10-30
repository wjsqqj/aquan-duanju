/// 派生同源（design.md §2）：章节 HTML → 显示段落的唯一入口，以及
/// **CRITICAL-1 的回归锁** —— 「设了替换规则 + 开了简繁时，阅读页与朗读控制器
/// 拿到的段落列表逐元素相等」。
///
/// 这条锁为什么必须存在：改造前页面在 getter 里做简繁、控制器只做
/// `htmlToParagraphs + 去标题`，两侧段数与偏移会错开且**不报错**（高亮偏段、
/// 词点指错字）。现在两侧同调 [deriveDisplayParagraphs]，段数与字符位相等是
/// 结构性结论，测试要把它钉住。
library;

import 'dart:io';

import 'package:aquan_duanju/core/reader/reader_paragraphs.dart';
import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:aquan_duanju/core/reader/replace_rules.dart';
import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tts/speech_fakes.dart';

/// 一条把整段广告吃掉的正则（替换后为空的段会被丢弃，这正是「删段」路径）。
const ReplaceRule _adRule = ReplaceRule(
  id: 'test-ad',
  name: '去广告段',
  pattern: r'广告\d+',
  replacement: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('deriveDisplayParagraphs 的顺序固定', () {
    test('① htmlToParagraphs ② 只去掉与章标题相同的首段', () {
      final out = deriveDisplayParagraphs(
        raw: '<p>第一章 起风了</p><p>甲乙丙。</p><p>第一章 起风了</p>',
        chapterTitle: '第一章 起风了',
        rules: const <ReplaceRule>[],
        convert: ChineseConvert.off,
      );
      expect(out, <String>['甲乙丙。', '第一章 起风了'], reason: '标题去重只看第一段，正文里同名段落必须留下');
    });

    test('③ 替换规则在简繁之前，且替换后为空的段被丢弃', () {
      final out = deriveDisplayParagraphs(
        raw: '<p>广告1</p><p>正文字。</p><p>尾注 广告2 结束</p>',
        chapterTitle: '第一章 起风了',
        rules: <ReplaceRule>[_adRule],
        convert: ChineseConvert.off,
      );
      // 只 trim 段首尾、段内空格不压缩：替换留下的双空格必须原样进缓存，
      // 否则页面与控制器拿到的段长不同，字符位就漂了。
      expect(out, <String>['正文字。', '尾注  结束']);
    });

    test('④ 简繁是最后一步，且不改变字符数（坐标系才不会漂）', () {
      const source = '<p>這個問題很難說清楚。</p>';
      final off = deriveDisplayParagraphs(
        raw: source,
        chapterTitle: '第一章 起风了',
        rules: const <ReplaceRule>[],
        convert: ChineseConvert.off,
      );
      final t2s = deriveDisplayParagraphs(
        raw: source,
        chapterTitle: '第一章 起风了',
        rules: const <ReplaceRule>[],
        convert: ChineseConvert.t2s,
      );
      expect(off, <String>['這個問題很難說清楚。']);
      expect(t2s, <String>['这个问题很难说清楚。']);
      expect(t2s.single.length, off.single.length);
    });

    test('规则与标题都不命中时，段落逐段原样保留', () {
      final out = deriveDisplayParagraphs(
        raw: '<p>甲。</p><p>乙。</p>',
        chapterTitle: '完全不同的标题',
        rules: const <ReplaceRule>[],
        convert: ChineseConvert.off,
      );
      expect(out, <String>['甲。', '乙。']);
    });
  });

  group('章内字符位工具', () {
    const paragraphs = <String>['甲乙丙', '丁戊', '己'];

    test('偏移按「段长 + 1 个换行」推进', () {
      expect(paragraphCharOffset(paragraphs, 0), 0);
      expect(paragraphCharOffset(paragraphs, 1), 4);
      expect(paragraphCharOffset(paragraphs, 2), 7);
      expect(paragraphCharOffset(paragraphs, 9), 7, reason: '越界夹到最后一段');
    });

    test('区间含起不含止，绝不吞掉分隔换行', () {
      expect(paragraphCharRange(paragraphs, 1), (4, 6));
      expect(paragraphCharRange(const <String>[], 0), isNull);
    });
  });

  group('CRITICAL-1 回归锁：页面与控制器逐元素相等', () {
    late Directory root;
    late SpeechHarness harness;
    late ReplaceRuleStore rules;
    late ReaderSettingsStore readerSettings;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      root = Directory.systemTemp.createTempSync('reader_paragraphs');
      harness = SpeechHarness('reader_paragraphs_tts');
      rules = ReplaceRuleStore(testDirectory: root);
      readerSettings = ReaderSettingsStore(testDirectory: root);
      await rules.ensureLoaded();
      await readerSettings.ensureLoaded();
      await rules.add(name: '去广告段', pattern: r'广告\d+', replacement: '');
      await readerSettings.update(
        readerSettings.value.copyWith(convert: ChineseConvert.s2t),
      );
      // 章标题 + 广告段 + 简体正文：三条派生步骤全都被 exercise 到。
      harness.api.html =
          '<p>第一章 起风了</p><p>广告1</p><p>这个问题的风停了。</p>'
          '<p>尾注 广告2 结束</p>';
    });

    tearDown(() {
      harness.dispose();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 阅读页那一侧的算法：`_deriveParagraphs` 只是它的薄封装（同参数、同入口）。
    List<String> pageParagraphs() => deriveDisplayParagraphs(
      raw: harness.api.html,
      chapterTitle: harnessChapters.first.title,
      rules: rules.forBook('7001'),
      convert: readerSettings.value.convert,
    );

    test('替换规则 + 简繁都开时，控制器得到的列表与页面**逐元素相等**', () async {
      final controller = harness.build(
        FakeTts(),
        rules: rules,
        settings: readerSettings,
      );
      await harness.start(controller);

      final page = pageParagraphs();
      expect(page, isNotEmpty);
      expect(
        controller.speechParagraphs,
        page,
        reason: '朗读文本与屏幕文本必须同源：段数与每段内容逐项相等',
      );
      expect(controller.playing, isTrue);
      // 广告段确实被删掉了、简繁确实生效了 —— 否则上面那条相等是巧合而非同源。
      expect(page.every((p) => !p.contains('广告')), isTrue);
      expect(page.first.contains('這'), isTrue);
      expect(page.first.contains('風'), isTrue);
    });

    test('同源之后，词点的字符区间在**页面文本**上逐字命中', () async {
      final controller = harness.build(
        FakeTts(),
        rules: rules,
        settings: readerSettings,
      );
      await harness.start(controller);

      // 控制器算出的 charStart/charEnd 是章内坐标；用页面的段落列表去解释它。
      // 只要两侧派生不同源，`substring` 出来的字就和引擎念的字不一样。
      final plain = chapterPlainText(controller.speechParagraphs);
      expect(plain, chapterPlainText(pageParagraphs()));
      final totalMs = plain.length * 10; // 假引擎每字 10ms
      var checked = 0;
      for (var ms = 0; ms < totalMs; ms += 3) {
        await harness.pumpPosition(ms);
        final word = controller.currentWord;
        if (word == null) continue;
        expect(word.charEnd <= plain.length, isTrue);
        expect(plain.substring(word.charStart, word.charEnd), word.text);
        checked++;
      }
      expect(checked, greaterThan(0), reason: '假引擎必须真的产出词点');
    });

    test('store 没注入时退化成「无规则 + 不转换」，与历史行为相等', () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);

      final page = deriveDisplayParagraphs(
        raw: harness.api.html,
        chapterTitle: harnessChapters.first.title,
        rules: const <ReplaceRule>[],
        convert: ChineseConvert.off,
      );
      expect(controller.speechParagraphs, page);
      expect(controller.playing, isTrue);
    });
  });
}
