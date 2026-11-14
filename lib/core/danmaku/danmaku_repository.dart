import '../aqua_api.dart';
import '../error_log.dart';
import '../../models/models.dart';

/// 弹幕仓库：按集翻页拉取并缓存，seek 越过已覆盖区间时从新位置重拉。
///
/// 语义要点（上游实测）：
/// - 空页不等于到底，必须翻到 hasMore=false；
/// - 服务端每台设备只下发精选的一部分弹幕，total 远大于实际可取条数；
/// - 拉取失败静默截断：返回已到手的部分，错误只进 ErrorLog——弹幕是
///   装饰性功能，绝不能干扰播放主链路。
class DanmakuRepository {
  DanmakuRepository(this._api);

  final AquaApi _api;

  final Map<String, _EpisodeDanmaku> _episodes = <String, _EpisodeDanmaku>{};
  final Set<String> _inflight = <String>{};

  /// 单次拉取循环的翻页上限：正常一集 2~8 页；触顶视为本轮完成
  /// （cursor 已记录，下次 load 会续翻）。
  static const _maxPagesPerCycle = 30;

  /// 覆盖区间的边缘容忍（毫秒）：落在覆盖区内不再触发重拉。
  static const _coverageSlackMs = 5000;

  /// 尽力拉齐 [positionMs] 之后的弹幕，返回该集当前已缓存的全部弹幕。
  Future<List<DanmakuItem>> load(
    String seriesId,
    String episodeId,
    int positionMs,
  ) async {
    final entry =
        _episodes.putIfAbsent(episodeId, () => _EpisodeDanmaku());
    if (_inflight.contains(episodeId)) {
      // 上一轮还在翻：直接回缓存，不叠加并发请求。
      return List<DanmakuItem>.unmodifiable(entry.items);
    }
    // 覆盖区判定：位置落在已覆盖区间（±容忍）内就回缓存；done 只对本窗
    // 有效——seek 跳出覆盖区（哪怕本窗已翻到头）也要从新位置开新窗。
    // 注意覆盖区是首尾包络，窗口中途失败留下的内部空洞不再补拉（可接受：
    // 只影响弹幕密度，下次 drop 后重建）。
    final covered = positionMs >= entry.coveredFromMs - _coverageSlackMs &&
        positionMs <= entry.coveredToMs + _coverageSlackMs;
    final needsFetch = !covered;
    if (needsFetch) {
      _inflight.add(episodeId);
      try {
        // 从当前位置开一扇新窗：cursor 清空 + startMs 指向新位置。
        entry.cursor = '';
        entry.done = false;
        for (var page = 0; page < _maxPagesPerCycle; page++) {
          final p = await _api.listDanmaku(
            seriesId,
            episodeId,
            startMs: entry.cursor.isEmpty ? positionMs : 0,
            cursor: entry.cursor,
          );
          var added = 0;
          for (final it in p.items) {
            if (entry.seen.add(it.id)) {
              entry.items.add(it);
              added++;
            }
          }
          if (p.startMs > 0 && p.startMs < entry.coveredFromMs) {
            entry.coveredFromMs = p.startMs;
          }
          if (p.endMs > 0 && p.endMs > entry.coveredToMs) {
            entry.coveredToMs = p.endMs;
          } else if (p.endMs <= 0 && p.startMs > entry.coveredToMs) {
            entry.coveredToMs = p.startMs + 30000;
          }
          if (p.total > 0) entry.total = p.total;
          if (!p.hasMore || p.cursor.isEmpty) {
            entry.done = true;
            break;
          }
          entry.cursor = p.cursor;
        }
      } catch (e, st) {
        // 静默降级：部分窗口丢失可接受（下次 seek 越界会续拉）。
        ErrorLog.instance
            .record('弹幕', '拉取失败（episode=$episodeId）：${_clip(e.toString())}', st);
      } finally {
        _inflight.remove(episodeId);
      }
    }
    entry.items.sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
    return List<DanmakuItem>.unmodifiable(entry.items);
  }

  /// 换集/关闭时丢弃缓存，防长会话内存增长。
  void drop(String episodeId) {
    _episodes.remove(episodeId);
  }

  static String _clip(String text, [int max = 160]) {
    final oneLine = text.replaceAll('\n', ' ⏎ ').trim();
    return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
  }
}

/// 单集弹幕的缓存态。
class _EpisodeDanmaku {
  final List<DanmakuItem> items = <DanmakuItem>[];
  final Set<String> seen = <String>{};

  /// 下一页游标；'' 表示从头（或已结束）。
  String cursor = '';

  /// 本集翻页是否到头。
  bool done = false;

  /// 已覆盖的播放时间区间（毫秒）；seek 落在区间外才触发重拉。
  int coveredFromMs = 1 << 62;
  int coveredToMs = -1;
  int total = 0;
}
