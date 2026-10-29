import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  group('ListenEntry', () {
    test('json 往返保留章节、位置与音色', () {
      final entry = ListenEntry(
        bookId: 'b1',
        title: '一本书',
        chapterTitle: '第3章',
        chapterIndex: 2,
        chapters: 100,
        toneId: 74,
        positionMs: 12345,
      );
      final back = ListenEntry.fromJson('b1', entry.toJson());
      expect(back.chapterIndex, 2);
      expect(back.chapterTitle, '第3章');
      expect(back.toneId, 74);
      expect(back.positionMs, 12345);
    });

    test('缺字段按默认值处理', () {
      final back = ListenEntry.fromJson('b2', const {});
      expect(back.positionMs, 0);
      expect(back.toneId, 0);
    });
  });
}