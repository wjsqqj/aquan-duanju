// 无头冒烟：Dart VM 直接加载 Go 核心 dll，对真实接口做一次
// 热搜 → 搜索 → 分集 → 播放地址 的全链路验证。
// 用法：dart run tool/smoke.dart <dll 绝对目录> [设备档案] [直连剧集ID]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:aquan_duanju/core/aqua_client.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/smoke.dart <含 aquan_core.dll 的目录>');
    exit(2);
  }
  final dir = args[0];
  // ffi_bridge 按名字加载；在 VM 里需要先把目录切到 dll 所在处。
  Directory.current = dir;

  // 复用同一个档案，减少注册次数（服务端对反复注册软限流）。
  final profile = args.length > 1
      ? args[1]
      : '${Directory.systemTemp.path}/aqua_smoke_device.json';
  final sw = Stopwatch()..start();
  final client = await AquaClient.create(profile);
  print('[ok] AquaNew (${sw.elapsedMilliseconds}ms)');

  Future<dynamic> call(String m, [List<Object?> a = const []]) async {
    sw.reset();
    final r = await client.call(m, a);
    print('[ok] $m (${sw.elapsedMilliseconds}ms)');
    return r;
  }

  // 1. 热搜
  final hot = await call('hotSearch') as Map<String, dynamic>;
  final guesses = hot['guesses'] as List<dynamic>? ?? const [];
  print('     热搜猜你想搜 ${guesses.length} 条');

  // 2. 搜索（服务端对部分环境软拒搜索；给了直连 seriesId 就跳过搜索）
  String seriesId;
  if (args.length > 2) {
    seriesId = args[2];
    print('     直连剧集 $seriesId（跳过搜索）');
  } else {
  final page = await call('search', ['霸总']) as Map<String, dynamic>;
  final items = page['items'] as List<dynamic>? ?? const [];
  if (items.isEmpty) {
    stderr.writeln('[fail] 搜索无结果');
    exit(1);
  }
  final first = items.first as Map<String, dynamic>;
  seriesId = first['id'] as String;
  print('     搜索第一条: ${first['title']} ($seriesId)');
  }

  // 3. 分集
  final eps = await call('listEpisodes', [seriesId]) as Map<String, dynamic>;
  final epItems = eps['items'] as List<dynamic>? ?? const [];
  if (epItems.isEmpty) {
    stderr.writeln('[fail] 无分集');
    exit(1);
  }
  final ep = epItems.first as Map<String, dynamic>;
  print('     分集 ${epItems.length} 个，第 1 集 id=${ep['id']}');

  // 4. 播放地址
  final pb = await call('resolvePlayback', [ep['id']]) as Map<String, dynamic>;
  final playback = pb['playback'] as Map<String, dynamic>;
  final streams = playback['streams'] as List<dynamic>? ?? const [];
  final key = pb['contentKey'] as Map<String, dynamic>?;
  print('     播放流 ${streams.length} 条, 加密=${playback['protected']}, '
      'contentKey=${key == null ? '无' : '有(${key['version']})'}');
  if (streams.isEmpty) {
    stderr.writeln('[fail] 无播放流');
    exit(1);
  }
  final firstStream = streams.first as Map<String, dynamic>;
  final url = (firstStream['url'] as String?) ?? '';
  print('     首条流: ${firstStream['definition']} ${url.substring(0, url.length > 60 ? 60 : url.length)}…');

  // 5. 版本
  print('[done] 全链路冒烟通过');
  exit(0);
}
