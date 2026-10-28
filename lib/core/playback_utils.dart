import '../models/models.dart';

/// 预解析的播放模型是否仍在有效期内（留 60 秒余量给打开动作）。
/// expiresAt 为 0（未知）时视为可用。
bool prefetchUsable(PlaybackResult pb, DateTime now) {
  final expires = pb.playback.expiresAt;
  if (expires <= 0) return true;
  final at = DateTime.fromMillisecondsSinceEpoch(expires * 1000);
  return at.isAfter(now.add(const Duration(seconds: 60)));
}
