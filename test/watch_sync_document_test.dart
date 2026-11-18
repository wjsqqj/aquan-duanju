import 'dart:convert';

import 'package:aquan_duanju/core/sync/watch_sync_document.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一条历史条目 map（形状与 HistoryEntry.toJson() 一致）。
Map<String, dynamic> historyEntry(
  String id, {
  required String updatedAt,
  int episode = 1,
}) => {
  'series_id': id,
  'title': '剧$id',
  'episode': episode,
  'episodes': 12,
  'finished': false,
  'position': 120.0,
  'updated_at': updatedAt,
};

/// 构造一条追剧条目 map（形状与 FollowEntry.toJson() 一致）。
Map<String, dynamic> followEntry(String id, {required String updatedAt}) => {
  'series_id': id,
  'title': '剧$id',
  'episode_count': 12,
  'state': 'watching',
  'updated_at': updatedAt,
};

WatchSyncDocument doc({
  List<Map<String, dynamic>> history = const [],
  List<Map<String, dynamic>> follows = const [],
  List<WatchTombstone> tombstones = const [],
  int exportedAt = 0,
}) => WatchSyncDocument(
  history: history,
  follows: follows,
  tombstones: tombstones,
  exportedAt: exportedAt,
);

void main() {
  // 锚点：2026-11-19（今天）。180 天墓碑窗口的边界用例都围绕它构造。
  final now = DateTime.utc(2026, 11, 19);
  final nowMs = now.millisecondsSinceEpoch;

  group('文档解析', () {
    test('JSON 往返保真', () {
      final origin = doc(
        history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
        follows: [followEntry('b', updatedAt: '2026-11-02T00:00:00.000Z')],
        tombstones: [
          WatchTombstone(
            kind: WatchEntryKind.follow,
            id: 'c',
            deletedAt: nowMs,
          ),
        ],
        exportedAt: nowMs,
      );
      final parsed = WatchSyncDocument.parse(jsonEncode(origin.toJson()));
      expect(parsed.history.single['series_id'], 'a');
      expect(parsed.follows.single['series_id'], 'b');
      expect(parsed.tombstones.single.id, 'c');
      expect(parsed.tombstones.single.kind, WatchEntryKind.follow);
      expect(parsed.exportedAt, nowMs);
    });

    test('坏 JSON / 结构错 → 明确报错（中止同步，不覆盖云端）', () {
      expect(
        () => WatchSyncDocument.parse('not json'),
        throwsA(isA<WatchSyncFormatException>()),
      );
      expect(
        () => WatchSyncDocument.parse('[1,2]'),
        throwsA(isA<WatchSyncFormatException>()),
      );
    });

    test('远端版本过新 → 中止同步', () {
      final text = jsonEncode({
        'version': 2,
        'history': <Object>[],
        'follows': <Object>[],
        'tombstones': <Object>[],
      });
      expect(
        () => WatchSyncDocument.parse(text),
        throwsA(isA<WatchSyncFormatException>()),
      );
    });

    test('缺 version / 字段缺失按默认处理，不炸', () {
      final parsed = WatchSyncDocument.parse('{"history": []}');
      expect(parsed.version, WatchSyncDocument.currentVersion);
      expect(parsed.history, isEmpty);
      expect(parsed.tombstones, isEmpty);
    });

    test('半坏条目被跳过（不带 series_id / 墓碑字段错）', () {
      final parsed = WatchSyncDocument.parse(
        jsonEncode({
          'version': 1,
          'history': [
            {'title': '没有 id'},
            historyEntry('ok', updatedAt: '2026-11-01T00:00:00.000Z'),
          ],
          'tombstones': [
            {'kind': 'history'},
            {'kind': 'history', 'id': 'ok', 'deletedAt': nowMs},
          ],
        }),
      );
      expect(parsed.history, hasLength(1));
      expect(parsed.history.single['series_id'], 'ok');
      expect(parsed.tombstones, hasLength(1));
      expect(parsed.tombstones.single.id, 'ok');
    });
  });

  group('条目合并（新者胜）', () {
    test('远端较新 → 远端赢，且本地要写入', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
        ),
        remote: doc(
          history: [
            historyEntry(
              'a',
              updatedAt: '2026-11-02T00:00:00.000Z',
              episode: 5,
            ),
          ],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.history.single['episode'], 5);
      expect(outcome.historyToApply, hasLength(1));
      expect(outcome.hasLocalChanges, isTrue);
    });

    test('本地较新 → 本地赢，不回写本地', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [
            historyEntry(
              'a',
              updatedAt: '2026-11-03T00:00:00.000Z',
              episode: 9,
            ),
          ],
        ),
        remote: doc(
          history: [
            historyEntry(
              'a',
              updatedAt: '2026-11-02T00:00:00.000Z',
              episode: 5,
            ),
          ],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.history.single['episode'], 9);
      expect(outcome.historyToApply, isEmpty);
    });

    test('同刻本地赢（双向都不改对方设备）', () {
      final stamp = '2026-11-02T00:00:00.000Z';
      final outcome = mergeWatchDocuments(
        local: doc(history: [historyEntry('a', updatedAt: stamp, episode: 7)]),
        remote: doc(history: [historyEntry('a', updatedAt: stamp, episode: 4)]),
        nowMs: nowMs,
      );
      expect(outcome.document.history.single['episode'], 7);
      expect(outcome.historyToApply, isEmpty);
    });

    test('只在一侧存在的条目直接并入；双侧为空则无事发生', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
        ),
        remote: doc(
          history: [historyEntry('b', updatedAt: '2026-11-01T00:00:00.000Z')],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.history, hasLength(2));
      // 远端新条目 b 要写进本地。
      expect(outcome.historyToApply.single['series_id'], 'b');
    });

    test('追剧条目同理归并（follows 独立于 history）', () {
      final stamp = '2026-11-02T00:00:00.000Z';
      final outcome = mergeWatchDocuments(
        local: doc(follows: [followEntry('f1', updatedAt: stamp)]),
        remote: doc(
          follows: [followEntry('f1', updatedAt: '2026-11-05T00:00:00.000Z')],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.follows.single['series_id'], 'f1');
      // 远端较新的那条 merged 出来还是远端 map（state 未变，字段同）——
      // 验证要写本地：时间严格更新。
      expect(outcome.followsToApply, hasLength(1));
    });
  });

  group('旧 JSON 无时间戳兼容', () {
    test('无 updated_at 的条目视为最旧：任何真实时间都赢', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [
            {'series_id': 'old', 'episode': 1}, // 旧数据：没有时间戳
          ],
        ),
        remote: doc(
          history: [historyEntry('old', updatedAt: '2026-11-02T00:00:00.000Z')],
        ),
        nowMs: nowMs,
      );
      // 远端（有时间戳）赢，回写本地补上进度。
      expect(outcome.document.history.single['episode'], 1);
      expect(outcome.document.history.single['updated_at'], isNotNull);
      expect(outcome.historyToApply, hasLength(1));
    });

    test('无时间戳 vs 无时间戳：同刻本地赢，不回写', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [
            {'series_id': 'old', 'episode': 3},
          ],
        ),
        remote: doc(
          history: [
            {'series_id': 'old', 'episode': 1},
          ],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.history.single['episode'], 3);
      expect(outcome.historyToApply, isEmpty);
    });

    test('坏时间戳（乱串）也按最旧处理，不抛异常', () {
      final outcome = mergeWatchDocuments(
        local: doc(history: [historyEntry('a', updatedAt: 'not-a-date')]),
        remote: doc(
          history: [historyEntry('a', updatedAt: '2026-11-02T00:00:00.000Z')],
        ),
        nowMs: nowMs,
      );
      expect(outcome.historyToApply, hasLength(1));
    });
  });

  group('墓碑', () {
    test('远端墓碑命中本地条目 → 删除生效（hits 返回，条目不进合并结果）', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
        ),
        remote: doc(
          tombstones: [
            WatchTombstone(
              kind: WatchEntryKind.history,
              id: 'a',
              deletedAt: DateTime.utc(2026, 11, 10).millisecondsSinceEpoch,
            ),
          ],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.history, isEmpty);
      expect(outcome.historyTombstoneHits, hasLength(1));
      expect(outcome.historyTombstoneHits.single.id, 'a');
      expect(outcome.hasLocalChanges, isTrue);
    });

    test('墓碑命中时同刻也算删除（删除意图优先），条目严格更新才复活', () {
      final stampMs = DateTime.utc(2026, 11, 10).millisecondsSinceEpoch;
      final stamp = DateTime.utc(2026, 11, 10).toIso8601String();
      final outcome = mergeWatchDocuments(
        local: doc(history: [historyEntry('a', updatedAt: stamp)]),
        remote: doc(
          tombstones: [
            WatchTombstone(
              kind: WatchEntryKind.history,
              id: 'a',
              deletedAt: stampMs,
            ),
          ],
        ),
        nowMs: nowMs,
      );
      expect(outcome.historyTombstoneHits, hasLength(1));
    });

    test('条目比墓碑新 → 复活，墓碑作废清理（删了又看）', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          history: [historyEntry('a', updatedAt: '2026-11-15T00:00:00.000Z')],
        ),
        remote: doc(
          tombstones: [
            WatchTombstone(
              kind: WatchEntryKind.history,
              id: 'a',
              deletedAt: DateTime.utc(2026, 11, 10).millisecondsSinceEpoch,
            ),
          ],
        ),
        nowMs: nowMs,
      );
      expect(outcome.document.history, hasLength(1));
      expect(outcome.historyTombstoneHits, isEmpty);
      expect(outcome.document.tombstones, isEmpty);
    });

    test('双侧都没有条目、只剩墓碑 → 墓碑保留（传播给其他设备）', () {
      final tombstone = WatchTombstone(
        kind: WatchEntryKind.follow,
        id: 'gone',
        deletedAt: DateTime.utc(2026, 11, 10).millisecondsSinceEpoch,
      );
      final outcome = mergeWatchDocuments(
        local: doc(),
        remote: doc(tombstones: [tombstone]),
        nowMs: nowMs,
      );
      expect(outcome.document.tombstones, hasLength(1));
      expect(outcome.followsTombstoneHits, isEmpty);
    });

    test('过期墓碑（>180 天）清理，不进合并结果', () {
      final stale = WatchTombstone(
        kind: WatchEntryKind.history,
        id: 'ancient',
        deletedAt:
            now.millisecondsSinceEpoch -
            const Duration(days: 181).inMilliseconds,
      );
      final fresh = WatchTombstone(
        kind: WatchEntryKind.history,
        id: 'recent',
        deletedAt:
            now.millisecondsSinceEpoch -
            const Duration(days: 179).inMilliseconds,
      );
      final outcome = mergeWatchDocuments(
        local: doc(tombstones: [stale]),
        remote: doc(tombstones: [fresh]),
        nowMs: nowMs,
      );
      expect(outcome.document.tombstones.single.id, 'recent');
    });

    test('同 id 墓碑取较新（本地重删时间戳更新）', () {
      final outcome = mergeWatchDocuments(
        local: doc(
          tombstones: [
            WatchTombstone(
              kind: WatchEntryKind.history,
              id: 'a',
              deletedAt: DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
            ),
          ],
        ),
        remote: doc(
          tombstones: [
            WatchTombstone(
              kind: WatchEntryKind.history,
              id: 'a',
              deletedAt: DateTime.utc(2026, 11, 5).millisecondsSinceEpoch,
            ),
          ],
        ),
        nowMs: nowMs,
      );
      expect(
        outcome.document.tombstones.single.deletedAt,
        DateTime.utc(2026, 11, 5).millisecondsSinceEpoch,
      );
    });

    test('墓碑超上限（>2000）清一次最老', () {
      // 全部落在 180 天保留窗口内（nowMs 往前推，i 越大越新）。
      final tombs = <WatchTombstone>[
        for (var i = 0; i < WatchSyncDocument.tombstoneLimit + 10; i++)
          WatchTombstone(
            kind: WatchEntryKind.history,
            id: 't$i',
            deletedAt:
                nowMs - (WatchSyncDocument.tombstoneLimit + 20 - i) * 60000,
          ),
      ];
      final outcome = mergeWatchDocuments(
        local: doc(tombstones: tombs),
        remote: doc(),
        nowMs: nowMs,
      );
      expect(
        outcome.document.tombstones,
        hasLength(WatchSyncDocument.tombstoneLimit),
      );
      // 最老的 10 条（t0..t9）被清掉。
      final ids = outcome.document.tombstones.map((t) => t.id).toSet();
      expect(ids.contains('t0'), isFalse);
      expect(ids.contains('t9'), isFalse);
      expect(ids.contains('t10'), isTrue);
    });
  });

  group('内容签名（跳写依据）', () {
    test('内容相同 → 签名相同（exportedAt 不参与）', () {
      final a = doc(
        history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
        exportedAt: 111,
      );
      final b = doc(
        history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
        exportedAt: 999,
      );
      expect(a.contentSignature(), b.contentSignature());
    });

    test('条目顺序 / map 键序不同 → 同签名（规范化排序）', () {
      final entry = historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z');
      // 同内容、键序不同。
      final reordered = <String, dynamic>{
        for (final k in entry.keys.toList().reversed) k: entry[k],
      };
      final a = doc(
        history: [
          entry,
          historyEntry('b', updatedAt: '2026-11-02T00:00:00.000Z'),
        ],
      );
      final b = doc(
        history: [
          historyEntry('b', updatedAt: '2026-11-02T00:00:00.000Z'),
          reordered,
        ],
      );
      expect(a.contentSignature(), b.contentSignature());
    });

    test('内容不同 → 签名不同', () {
      final a = doc(
        history: [historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z')],
      );
      final b = doc(
        history: [
          historyEntry('a', updatedAt: '2026-11-01T00:00:00.000Z', episode: 2),
        ],
      );
      expect(a.contentSignature(), isNot(b.contentSignature()));
    });

    test('墓碑变化也反映在签名里', () {
      final a = doc();
      final b = doc(
        tombstones: [
          WatchTombstone(
            kind: WatchEntryKind.history,
            id: 'x',
            deletedAt: nowMs,
          ),
        ],
      );
      expect(a.contentSignature(), isNot(b.contentSignature()));
    });
  });
}
