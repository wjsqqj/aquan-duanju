import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:flutter_test/flutter_test.dart';

/// 朗读单元的坐标系不变量测试。断言全部针对
/// `.trellis/spec/frontend/reader-paging-contract.md` §9.1 的字符位约定。
void main() {
  /// 校验四条不变量：文本可由坐标还原、不重叠递增、间隙只有空白、无空白 unit。
  void expectInvariants(List<String> paragraphs, {int? maxUnitChars}) {
    final units = splitSpeechUnits(
      paragraphs,
      maxUnitChars: maxUnitChars ?? kDefaultMaxUnitChars,
    );
    final plain = chapterPlainText(paragraphs);
    var prevEnd = -1;
    for (final u in units) {
      expect(
        u.text,
        plain.substring(u.charStart, u.charEnd),
        reason: 'unit ${u.index} 文本必须与坐标一致',
      );
      expect(u.text.trim(), isNotEmpty, reason: '不允许空白 unit');
      expect(u.charStart, greaterThanOrEqualTo(prevEnd), reason: 'unit 不得重叠');
      expect(u.charEnd, greaterThan(u.charStart));
      if (prevEnd >= 0) {
        expect(
          plain.substring(prevEnd, u.charStart).trim(),
          isEmpty,
          reason: '相邻 unit 之间只能跳过空白',
        );
      }
      prevEnd = u.charEnd;
      expect(u.paragraphIndex, lessThan(paragraphs.length));
    }
    // 正文一个字符都不能丢：所有 unit 拼回去去掉空白后必须等于原文去空白。
    final joined = units.map((u) => u.text).join();
    expect(
      joined.replaceAll(RegExp(r'\s'), ''),
      plain.replaceAll(RegExp(r'\s'), ''),
      reason: '切分不得丢字',
    );
  }

  group('切分与坐标', () {
    test('多段 + 段首全角缩进 + 空段仍然守恒', () {
      final paragraphs = <String>[
        '　　今天天气不错。我们出去走走吧！',
        '',
        '“真的？”她问。',
        '　　“真的。”',
        '   ',
        '结尾没有标点',
      ];
      expectInvariants(paragraphs);
    });

    test('句子边界落在句末标点之后，闭合引号归同一句', () {
      final units = splitSpeechUnits(<String>['他说“走了。”然后转身。第二句。']);
      expect(units.map((u) => u.text).toList(), <String>[
        '他说“走了。”',
        '然后转身。',
        '第二句。',
      ]);
      expectInvariants(<String>['他说“走了。”然后转身。第二句。']);
    });

    test('引号内整句收在闭合符号处，不把 ” 单独切成一段', () {
      final units = splitSpeechUnits(<String>['“明天见！”她笑着说。']);
      expect(units.first.text, '“明天见！”');
      expect(units.last.text, '她笑着说。');
    });

    test('英文标点与空段混排', () {
      expectInvariants(<String>[
        'Hello world. Is this working? Yes! It does; fine.',
        '   ',
        'Done.',
      ]);
    });

    test('空输入返回空列表', () {
      expect(splitSpeechUnits(const <String>[]), isEmpty);
    });

    test('整段只有空白不产生 unit', () {
      expect(splitSpeechUnits(<String>['   ', '\t  ']), isEmpty);
    });
  });

  group('超长句二次切分', () {
    test('优先断在次级标点，且长度受限', () {
      final long =
          '这是一段没有句号的很长的话，'
              '中间有逗号分隔，' *
          10;
      final units = splitSpeechUnits(<String>[long], maxUnitChars: 40);
      expect(units.length, greaterThan(1));
      for (final u in units) {
        // 断在次级标点会让实际长度略小于上限，但不该明显超出。
        expect(u.length, lessThanOrEqualTo(48), reason: u.text);
      }
      expectInvariants(<String>[long], maxUnitChars: 40);
    });

    test('没有任何标点时硬切也不丢字不劈代理对', () {
      final plain = '${'字' * 130}🙂${' word' * 30}';
      final units = splitSpeechUnits(<String>[plain], maxUnitChars: 50);
      expectInvariants(<String>[plain], maxUnitChars: 50);
      for (final u in units) {
        final endCode = plain.codeUnitAt(u.charEnd - 1);
        // unit 结尾不能是高代理（那会把 emoji 劈成两半）。
        expect(
          endCode >= 0xD800 && endCode <= 0xDBFF,
          isFalse,
          reason: 'unit 结尾劈开了代理对',
        );
      }
    });

    test('非法上限回退到默认值', () {
      final a = splitSpeechUnits(<String>['一。二。'], maxUnitChars: 0);
      expect(a.length, 2);
    });
  });

  group('unit 序号', () {
    test('连续递增且与列表位置一致', () {
      final units = splitSpeechUnits(<String>['甲。乙。丙。', '丁。']);
      for (var i = 0; i < units.length; i++) {
        expect(units[i].index, i);
      }
    });
  });
}
