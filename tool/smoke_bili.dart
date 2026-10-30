// 一次性冒烟：未登录走 buvid/bili_ticket + WBI 搜索 + 视频详情 + playurl。
import 'dart:io';

import 'package:aquan_duanju/core/bili/api.dart';
import 'package:aquan_duanju/core/bili/session.dart';

Future<void> main() async {
  final session = BiliSession();
  await session.load();
  final api = BiliApi(session);
  stdout.writeln('未登录冒烟开始…');
  try {
    await session.ensureRiskParams();
    stdout.writeln('buvid3=${session.buvid3?.substring(0, 16)}…');
    final results = await api.search('三体');
    stdout.writeln('搜索「三体」：${results.length} 条');
    for (final r in results.take(3)) {
      stdout.writeln('  [${r.kind.name}] ${r.title} | ${r.id}');
    }
    final video = results.where((r) => r.kind == BiliItemKind.video).firstOrNull;
    if (video != null) {
      final detail = await api.videoDetail(video.id);
      stdout.writeln('详情：${detail.title}（${detail.pages.length}P，cid=${detail.pages.first.cid}）');
      final play = await api.playUrls(
          cid: detail.pages.first.cid, bvid: detail.bvid);
      stdout.writeln(
          'playurl：video=${play.videos.length} audio=${play.audios.length} '
          'preview=${play.isPreview} first=${play.videos.firstOrNull?.height}p');
    }
    final season = results.where((r) => r.kind == BiliItemKind.season).firstOrNull;
    if (season != null) {
      final s = await api.season(seasonId: season.id);
      stdout.writeln('番剧：${s.title}，${s.episodes.length} 集');
    }
    stdout.writeln('冒烟通过');
  } catch (e) {
    stdout.writeln('冒烟失败：$e');
    exit(1);
  } finally {
    session.close();
  }
  exit(0);
}
