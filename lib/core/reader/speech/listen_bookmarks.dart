/// 听书书签：听到某处记一笔，之后能跳回来。
///
/// **键前缀故意不是 `listen.`**：那个前缀会被「恢复听书默认设置」整段清掉，
/// 而书签是**用户数据**，不该因为复位偏好而消失。所以用 `listenmark.`。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条听书书签。位置用「章节 + 章内毫秒」，与播放器时间轴同口径。
class ListenBookmark {
  const ListenBookmark({
    required this.id,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.positionMs,
    required this.createdAt,
  });

  final String id;
  final int chapterIndex;
  final String chapterTitle;
  final int positionMs;
  final int createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
    'positionMs': positionMs,
    'createdAt': createdAt,
  };

  /// 坏条目一律返回 null（单条坏数据不该让整张书签表消失）。
  static ListenBookmark? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final chapterIndex = raw['chapterIndex'];
    final positionMs = raw['positionMs'];
    if (id is! String || id.isEmpty) return null;
    if (chapterIndex is! num || positionMs is! num) return null;
    return ListenBookmark(
      id: id,
      chapterIndex: chapterIndex.toInt(),
      chapterTitle: '${raw['chapterTitle'] ?? ''}',
      positionMs: positionMs.toInt() < 0 ? 0 : positionMs.toInt(),
      createdAt: raw['createdAt'] is num
          ? (raw['createdAt'] as num).toInt()
          : 0,
    );
  }
}

/// 按书存的书签表（`SharedPreferences` 里一个 JSON，量级很小）。
class ListenBookmarks {
  ListenBookmarks(this._prefs);

  /// 见文件头：故意不用 `listen.` 前缀，避免被「恢复默认」清掉。
  static const String storageKey = 'listenmark.bookmarks';

  /// 每本书最多留多少条：再多说明用户在当"目录"用，该用阅读书签了。
  static const int perBookLimit = 50;

  final SharedPreferences _prefs;

  /// 书中书签，**新的在前**（用户通常想回到最近标记的地方）。
  List<ListenBookmark> of(String bookId) {
    final all = _readAll();
    final raw = all[bookId];
    if (raw is! List) return const <ListenBookmark>[];
    final out = raw
        .map(ListenBookmark.tryParse)
        .whereType<ListenBookmark>()
        .toList(growable: false);
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// 加一条；超过 [perBookLimit] 时丢最旧的。
  Future<void> add(String bookId, ListenBookmark mark) async {
    if (bookId.isEmpty) return;
    final all = _readAll();
    final list = <Map<String, dynamic>>[];
    final existing = all[bookId];
    if (existing is List) {
      for (final item in existing) {
        final parsed = ListenBookmark.tryParse(item);
        if (parsed != null) list.add(parsed.toJson());
      }
    }
    list.add(mark.toJson());
    // 新的在前、最多留 perBookLimit 条。
    list.sort(
      (a, b) =>
          (b['createdAt'] as int? ?? 0).compareTo(a['createdAt'] as int? ?? 0),
    );
    if (list.length > perBookLimit) list.removeRange(perBookLimit, list.length);
    all[bookId] = list;
    await _writeAll(all);
  }

  Future<void> remove(String bookId, String id) async {
    final all = _readAll();
    final existing = all[bookId];
    if (existing is! List) return;
    all[bookId] = existing
        .where((item) => ListenBookmark.tryParse(item)?.id != id)
        .toList(growable: false);
    await _writeAll(all);
  }

  Future<void> clear(String bookId) async {
    final all = _readAll();
    if (!all.containsKey(bookId)) return;
    all.remove(bookId);
    await _writeAll(all);
  }

  Map<String, dynamic> _readAll() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> all) async {
    try {
      await _prefs.setString(storageKey, jsonEncode(all));
    } catch (_) {
      // 写失败下次再试；书签不是关键路径。
    }
  }
}
