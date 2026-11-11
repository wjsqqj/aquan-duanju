import 'package:aquan_duanju/core/search/paging_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hasMoreAfterPage', () {
    test('服务端说没有下一页', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: false,
          requestCursor: '20',
          nextCursor: '40',
          newItemCount: 20,
        ),
        isFalse,
      );
    });

    test('游标正常推进且本页有新增 → 继续翻', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: true,
          requestCursor: '20',
          nextCursor: '40',
          newItemCount: 18,
        ),
        isTrue,
      );
    });

    test('首页（请求游标为空）推进到非空游标 → 继续翻', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: true,
          requestCursor: '',
          nextCursor: '20',
          newItemCount: 20,
        ),
        isTrue,
      );
    });

    test('本页 0 新增（整页重复或空页）→ 判定到底', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: true,
          requestCursor: '20',
          nextCursor: '40',
          newItemCount: 0,
        ),
        isFalse,
      );
    });

    test('游标为空 → 判定到底（再翻会重拉第一页）', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: true,
          requestCursor: '20',
          nextCursor: '',
          newItemCount: 5,
        ),
        isFalse,
      );
    });

    test('游标未推进 → 判定到底（同一游标不得重复请求）', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: true,
          requestCursor: '20',
          nextCursor: '20',
          newItemCount: 5,
        ),
        isFalse,
      );
    });

    test('首页也拿回空游标（服务端完全没给）→ 判定到底', () {
      expect(
        hasMoreAfterPage(
          serverHasMore: true,
          requestCursor: '',
          nextCursor: '',
          newItemCount: 3,
        ),
        isFalse,
      );
    });
  });
}
