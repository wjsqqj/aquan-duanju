/// 听书（智能朗读）相关模型，与 core 的 `audioTones` / `audioPlay` 输出一一对应。
library;

/// 一个音色（智能朗读或真人讲书）。
class AudioTone {
  const AudioTone({
    required this.id,
    this.title = '',
    this.icon = '',
  });

  final int id;
  final String title;
  final String icon;

  factory AudioTone.fromJson(Map<String, dynamic> json) => AudioTone(
        id: (json['id'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
      );
}

/// 某本书可用的音色列表。
class AudioTones {
  const AudioTones({
    this.bookId = '',
    this.relateBookId = '',
    this.genreType = 0,
    this.tones = const [],
  });

  final String bookId;

  /// 原著小说 id（智能朗读挂在原著上）。
  final String relateBookId;

  /// 1 表示这本书本身是有声书。
  final int genreType;
  final List<AudioTone> tones;

  bool get isEmpty => tones.isEmpty;

  /// 有声书（真人录音）优先，其次智能朗读。
  bool get hasRecordedAudio => genreType == 1;

  factory AudioTones.fromJson(Map<String, dynamic> json) => AudioTones(
        bookId: json['book_id'] as String? ?? '',
        relateBookId: json['relate_book_id'] as String? ?? '',
        genreType: (json['genre_type'] as num?)?.toInt() ?? 0,
        tones: (json['tones'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AudioTone.fromJson)
            .where((t) => t.id > 0)
            .toList(),
      );
}

/// 一条音轨（可播放的音频流）。
class AudioTrack {
  const AudioTrack({
    this.url = '',
    this.backupUrl = '',
    this.keyHex = '',
    this.durationMs = 0,
    this.encrypted = false,
  });

  final String url;
  final String backupUrl;

  /// CENC 内容密钥（hex）；加密流必须带上才能解。
  final String keyHex;
  final int durationMs;
  final bool encrypted;

  bool get isPlayable => url.isNotEmpty;

  factory AudioTrack.fromJson(Map<String, dynamic> json) => AudioTrack(
        url: json['url'] as String? ?? '',
        backupUrl: json['backup_url'] as String? ?? '',
        keyHex: json['key'] as String? ?? '',
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        encrypted: json['encrypted'] as bool? ?? false,
      );
}
/// 落盘后的音轨（core 下载到本地，播放器直接播文件）。
class AudioStream {
  const AudioStream({
    this.path = '',
    this.keyHex = '',
    this.bytes = 0,
    this.durationMs = 0,
    this.encrypted = false,
  });

  /// 本地文件路径。
  final String path;

  /// CENC 内容密钥（hex）。
  final String keyHex;
  final int bytes;

  /// 该章时长（毫秒），用于按阅读比例定位听书起点。
  final int durationMs;
  final bool encrypted;

  bool get isPlayable => path.isNotEmpty;

  factory AudioStream.fromJson(Map<String, dynamic> json) => AudioStream(
        path: json['path'] as String? ?? '',
        keyHex: json['key'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        encrypted: json['encrypted'] as bool? ?? false,
      );
}
/// 音频时间点：段落 ↔ 毫秒的映射点。
class AudioTimepoint {
  const AudioTimepoint({
    this.startMs = 0,
    this.endMs = 0,
    this.para = -1,
    this.paraOff = 0,
  });

  final int startMs;
  final int endMs;

  /// 上游的段落编号；-1 表示未知。
  final int para;
  final int paraOff;

  factory AudioTimepoint.fromJson(Map<String, dynamic> json) => AudioTimepoint(
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        para: (json['para'] as num?)?.toInt() ?? -1,
        paraOff: (json['para_off'] as num?)?.toInt() ?? 0,
      );
}

/// 一章的时间点集合。
class AudioTimepoints {
  const AudioTimepoints({this.points = const []});

  final List<AudioTimepoint> points;

  bool get isEmpty => points.isEmpty;

  /// 把「读到第几段 + 章内比例」换算成毫秒。
  ///
  /// 段落编号能对上时用精确值；对不上（上游切段与我们的 HTML 清洗不完全一致）
  /// 就按比例在时间点序列里插值——时间点反映真实语音分布，比按时长等分准。
  int offsetMs({required int paragraphIndex, required double ratio}) {
    if (points.isEmpty) return 0;
    for (final p in points) {
      if (p.para == paragraphIndex) return p.startMs;
    }
    final idx = (ratio.clamp(0.0, 1.0) * (points.length - 1))
        .round()
        .clamp(0, points.length - 1);
    return points[idx].startMs;
  }

  /// 反向换算：当前播放毫秒 → 本地段落下标。
  ///
  /// 上游 `para` 与本地清洗后的段落编号不一定一致，所以有 `para` 时优先用精确值
  /// （clamp 到本地段落数），没有时按时间点序号比例插值——与 [offsetMs] 共用同一套
  /// 「精确优先、比例兜底」假设。
  int paragraphAt(int ms, {required int paragraphCount}) {
    if (paragraphCount <= 0 || points.isEmpty) return 0;
    AudioTimepoint? known;
    for (final p in points) {
      if (p.para < 0) continue;
      if (p.startMs <= ms) {
        known = p;
      } else {
        break;
      }
    }
    if (known != null) return known.para.clamp(0, paragraphCount - 1);
    var idx = 0;
    for (var i = 0; i < points.length; i++) {
      if (points[i].startMs <= ms) idx = i;
    }
    if (points.length <= 1) return 0;
    final ratio = idx / (points.length - 1);
    return (ratio * (paragraphCount - 1)).round().clamp(0, paragraphCount - 1);
  }

  /// 正向换算：本地段落下标 → 毫秒（用于「跳到某段」）。
  ///
  /// 有 `para` 时用精确值；没有时按段落比例落到时间点序列上。
  int startMsOfParagraph(int index, {required int paragraphCount}) {
    if (points.isEmpty) return 0;
    for (final p in points) {
      if (p.para == index) return p.startMs;
    }
    if (paragraphCount <= 1) return points.first.startMs;
    final clamped = index.clamp(0, paragraphCount - 1);
    final ratio = clamped / (paragraphCount - 1);
    final pos = (ratio * (points.length - 1)).round().clamp(0, points.length - 1);
    return points[pos].startMs;
  }

  factory AudioTimepoints.fromJson(Map<String, dynamic> json) => AudioTimepoints(
        points: (json['points'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AudioTimepoint.fromJson)
            .toList(),
      );
}