/// 历史记录的分类归属。
///
/// 短剧/漫剧/电影同属 `ContentKind.video`，但「继续观看」必须各看各的：
/// 历史里 `contentType` 为空的是升级前的旧记录，按短剧归类（绝大多数历史
/// 都是短剧），不能按「未知」到处显示、也不能从所有分类里消失。
library;

import '../store/stores.dart';
import 'discover_channels.dart';

/// 旧记录兜底为短剧。
String contentTypeForHistory(HistoryEntry entry) =>
    entry.contentType.isEmpty ? kShortPlayType.name : entry.contentType;

/// 该历史是否属于发现页当前类型。
bool historyBelongsTo(HistoryEntry entry, String contentType) =>
    contentTypeForHistory(entry) == contentType;

/// 取当前类型下最近未看完的历史（按 `updatedAt` 倒序，最多 [limit] 条）。
List<HistoryEntry> resumableHistoryFor(
  Iterable<HistoryEntry> entries,
  String contentType, {
  int limit = 10,
}) =>
    entries
        .where((entry) => !entry.finished && historyBelongsTo(entry, contentType))
        .take(limit)
        .toList();
