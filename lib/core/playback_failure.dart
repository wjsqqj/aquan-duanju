/// 播放失败分类：决定「要不要自动换线、等不等防抖」。
///
/// - [permanent]：重试没有意义（域名不解析、HTTP 4xx/5xx、格式不支持）→ 立即换线；
/// - [transient]：可能只是抖动（超时、连接重置 / 拒绝、网络不可达）→ 保留防抖，
///   期间播放位置前进就取消换线；
/// - [unknown]：无法归类 → 按瞬时处理（保守），避免把可恢复的错误当永久错误。
enum PlaybackFailureKind { permanent, transient, unknown }

/// 一次失败的「用户文案 + 类型 + 原始错误」：文案与类型由同一判定产出，
/// 避免规则漂移；原始错误只用于诊断面板，不直接展示。
class PlaybackFailure {
  const PlaybackFailure({
    required this.message,
    required this.kind,
    this.raw = '',
  });

  final String message;
  final PlaybackFailureKind kind;
  final String raw;

  bool get permanent => kind == PlaybackFailureKind.permanent;

  @override
  String toString() => 'PlaybackFailure($kind, $message)';
}

/// 把播放器底层错误（libmpv / 网络栈）归类。
PlaybackFailure classifyPlaybackFailure(String? raw) {
  final text = (raw ?? '').toLowerCase();
  if (text.trim().isEmpty) {
    return const PlaybackFailure(
      message: '播放遇到错误，请稍后重试或切换线路',
      kind: PlaybackFailureKind.unknown,
    );
  }
  if (text.contains('resolve hostname') ||
      text.contains('does not resolve') ||
      text.contains('could not resolve') ||
      text.contains('name or service not known') ||
      text.contains('nodename nor servname')) {
    return PlaybackFailure(
      message: '无法解析播放地址的域名，请检查网络或切换线路',
      kind: PlaybackFailureKind.permanent,
      raw: raw!,
    );
  }
  if (text.contains('http error') ||
      RegExp(r'\b(?:400|401|403|404|410|500|502|503|504)\b').hasMatch(text)) {
    return PlaybackFailure(
      message: '播放地址不可用（服务器返回错误），请切换线路',
      kind: PlaybackFailureKind.permanent,
      raw: raw!,
    );
  }
  if (text.contains('format not supported') ||
      text.contains('unsupported format') ||
      text.contains('recognize file format') ||
      text.contains('could not open codec')) {
    return PlaybackFailure(
      message: '播放地址不可用（格式不受支持），请切换线路',
      kind: PlaybackFailureKind.permanent,
      raw: raw!,
    );
  }
  if (text.contains('no audio or video data') ||
      text.contains('no video or audio data') ||
      text.contains('did not contain any playable streams') ||
      text.contains('no video or audio streams')) {
    return PlaybackFailure(
      message: '播放源没有返回可播放的音视频数据（可能已失效），请稍后重试或切换线路',
      kind: PlaybackFailureKind.transient,
      raw: raw!,
    );
  }
  // 先判瞬时错误：mpv 的 "Failed to open ...: Connection timed out" 同时
  // 命中下面的通用兜底，顺序错了会把可恢复的超时当成永久错误。
  if (text.contains('connection refused') ||
      text.contains('connection timed out') ||
      text.contains('timed out') ||
      text.contains('network is unreachable') ||
      text.contains('connection reset') ||
      text.contains('temporary failure in name resolution')) {
    return PlaybackFailure(
      message: '连接播放服务器失败，请稍后重试或切换线路',
      kind: PlaybackFailureKind.transient,
      raw: raw!,
    );
  }
  if (text.contains('failed to open') || text.contains('could not open')) {
    return PlaybackFailure(
      message: '播放地址无法打开，请切换线路或稍后重试',
      kind: PlaybackFailureKind.permanent,
      raw: raw!,
    );
  }
  return PlaybackFailure(
    message: '播放遇到错误，请稍后重试或切换线路',
    kind: PlaybackFailureKind.unknown,
    raw: raw!,
  );
}
