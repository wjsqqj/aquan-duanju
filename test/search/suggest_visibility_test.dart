import 'package:aquan_duanju/core/search/suggest_visibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isEditingQuery', () {
    test('空输入不算编辑', () {
      expect(isEditingQuery('', '修仙'), isFalse);
      expect(isEditingQuery('   ', '修仙'), isFalse);
    });

    test('与已提交词相同不算编辑（刚提交完）', () {
      expect(isEditingQuery('修仙', '修仙'), isFalse);
      expect(isEditingQuery(' 修仙 ', '修仙'), isFalse);
    });

    test('改了词就算编辑', () {
      expect(isEditingQuery('修仙2', '修仙'), isTrue);
      expect(isEditingQuery('修', '修仙'), isTrue);
    });
  });

  group('shouldShowSuggestions', () {
    test('结果页二次输入 + 有联想 → 显示', () {
      expect(
        shouldShowSuggestions(
          input: '修仙',
          submitted: '都市',
          suggestionCount: 5,
        ),
        isTrue,
      );
    });

    test('联想还没回来 / 空表 → 不抢占结果', () {
      expect(
        shouldShowSuggestions(input: '修仙', submitted: '都市', suggestionCount: 0),
        isFalse,
      );
    });

    test('刚提交完（输入与已提交一致）→ 留在结果页', () {
      expect(
        shouldShowSuggestions(
          input: '修仙',
          submitted: '修仙',
          suggestionCount: 8,
        ),
        isFalse,
      );
    });
  });
}
