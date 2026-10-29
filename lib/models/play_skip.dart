/// 片头 / 片尾跳过偏好（按影片维度共享，跨集继承）。
///
/// 语义：
/// - [openingMs]：**从头起跳过的绝对毫秒**（每次从 0 开始播放时生效）；
/// - [endingMs]：**距片尾的尾部偏移毫秒**（`duration - endingMs` 为片尾起点）。
///
/// 单条解析容错：字段缺失按 0，超出 24h 视为无效并归零；整份文件版本不符时
/// 由调用方丢弃（见 PlaySkipStore），避免半坏文件拖垮播放。
class PlaySkipEntry {
  static const int maxMs = 24 * 60 * 60 * 1000;

  final int openingMs;
  final int endingMs;

  /// 最近一次修改时间（用于超出上限时淘汰最旧记录）。
  final int updatedAt;

  const PlaySkipEntry({
    this.openingMs = 0,
    this.endingMs = 0,
    this.updatedAt = 0,
  });

  bool get isEmpty => openingMs <= 0 && endingMs <= 0;

  static int normalize(int value) => (value < 0 || value > maxMs) ? 0 : value;

  PlaySkipEntry copyWith({int? openingMs, int? endingMs, int? updatedAt}) =>
      PlaySkipEntry(
        openingMs: normalize(openingMs ?? this.openingMs),
        endingMs: normalize(endingMs ?? this.endingMs),
        updatedAt: updatedAt ?? this.updatedAt,
      );

  static PlaySkipEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final opening = raw['opening_ms'] ?? raw['openingMs'];
    final ending = raw['ending_ms'] ?? raw['endingMs'];
    final updated = raw['updated_at'] ?? raw['updatedAt'];
    if (opening != null && opening is! num) return null;
    if (ending != null && ending is! num) return null;
    if (updated != null && updated is! num) return null;
    return PlaySkipEntry(
      openingMs: normalize((opening as num?)?.toInt() ?? 0),
      endingMs: normalize((ending as num?)?.toInt() ?? 0),
      updatedAt: (updated as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'opening_ms': openingMs,
    'ending_ms': endingMs,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is PlaySkipEntry &&
      other.openingMs == openingMs &&
      other.endingMs == endingMs &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(openingMs, endingMs, updatedAt);

  @override
  String toString() =>
      'PlaySkipEntry(openingMs: $openingMs, endingMs: $endingMs)';
}
