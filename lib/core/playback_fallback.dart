import '../models/models.dart';

/// 一条备用线路候选。
class PlaybackCandidate {
  const PlaybackCandidate({
    required this.url,
    required this.label,
    required this.stream,
    this.backup = false,
  });

  final String url;

  /// 展示用标签，如「720p」「720p · 备用」。
  final String label;
  final VideoStream stream;

  /// 是否来自 VideoStream.backupUrl。
  final bool backup;
}

/// 流清晰度排序权重：height 优先，其次从 definition 解析「720p」这类前缀，
/// 都拿不到时返回 0（未知）。
int streamRank(VideoStream s) {
  if (s.height > 0) return s.height;
  final digits = RegExp(r'^(\d+)').firstMatch(s.definition)?.group(1);
  return digits == null ? 0 : int.parse(digits);
}

/// 清晰度标签（与播放器 UI 的显示规则一致）。
String streamLabel(VideoStream s) => s.definition.isNotEmpty
    ? s.definition
    : (s.quality.isEmpty ? '默认' : s.quality);

/// 规划当前流的备用候选（纯函数，便于单测）。
///
/// 顺序：
/// 1. 当前流的 backupUrl（同清晰度，最可能直接可用）；
/// 2. 同清晰度的其他流（不同 codec / 副本）；
/// 3. 其他清晰度按「与当前清晰度档位距离」从近到远，同距离优先更低档
///    （省流量），再按码率从高到低。
///
/// 规则：跳过空地址、当前地址、已尝试地址（[tried]），按 URL 去重；
/// 绝不把同一地址重复塞进候选列表。
List<PlaybackCandidate> planPlaybackCandidates({
  required List<VideoStream> streams,
  required VideoStream current,
  required Set<String> tried,
  int maxCandidates = 4,
}) {
  final currentUrl = current.url.trim();
  final currentLabel = streamLabel(current);
  final currentRank = streamRank(current);
  final out = <PlaybackCandidate>[];
  final seen = <String>{currentUrl};

  void add(String url, VideoStream stream, String label, bool backup) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || seen.contains(trimmed) || tried.contains(trimmed)) {
      return;
    }
    seen.add(trimmed);
    out.add(
      PlaybackCandidate(
        url: trimmed,
        label: label,
        stream: stream,
        backup: backup,
      ),
    );
  }

  // 1. 当前流自带的备用地址。
  add(current.backupUrl, current, '$currentLabel · 备用', true);

  // 2. 同清晰度的其他流。
  for (final s in streams) {
    if (s.url.trim() == currentUrl || streamLabel(s) != currentLabel) continue;
    add(s.url, s, streamLabel(s), false);
    add(s.backupUrl, s, '${streamLabel(s)} · 备用', true);
  }

  // 3. 其他清晰度：距离近的优先。
  final others =
      streams
          .where(
            (s) =>
                s.url.trim().isNotEmpty &&
                s.url.trim() != currentUrl &&
                streamLabel(s) != currentLabel,
          )
          .toList()
        ..sort((a, b) {
          final da = _distance(streamRank(a), currentRank);
          final db = _distance(streamRank(b), currentRank);
          if (da != db) return da.compareTo(db);
          final ra = streamRank(a);
          final rb = streamRank(b);
          if (ra != rb) return ra.compareTo(rb);
          return b.bitrate.compareTo(a.bitrate);
        });
  for (final s in others) {
    add(s.url, s, streamLabel(s), false);
    add(s.backupUrl, s, '${streamLabel(s)} · 备用', true);
  }

  if (out.length <= maxCandidates) return List.unmodifiable(out);
  return List.unmodifiable(out.take(maxCandidates));
}

int _distance(int rank, int currentRank) {
  if (rank <= 0) return 1000;
  if (currentRank <= 0) return rank;
  return (rank - currentRank).abs();
}
