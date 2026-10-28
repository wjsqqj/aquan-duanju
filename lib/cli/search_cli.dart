import 'dart:convert';
import 'dart:io';

import '../core/aqua_api.dart';
import '../core/aqua_client.dart';
import '../core/aqua_error.dart';
import 'launch_command.dart';

/// `--search` 的无窗口模式：只调一次接口，把编号列表打到 stdout 就退出。
/// AI 助手拿到列表后，把某一行的 ID 通过 `--series` 再传回来。
Future<void> runSearchCli(LaunchCommand command, String profilePath) async {
  try {
    final client = await AquaClient.create(profilePath);
    final page = await AquaApi(client)
        .search(command.value, pageSize: command.limit);
    if (command.json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert({
        'query': command.value,
        'items': [
          for (final item in page.items)
            {
              'id': item.id,
              'title': item.title,
              'episode_count': item.episodeCount,
            }
        ],
      }));
      exit(0);
    }
    if (page.items.isEmpty) {
      stdout.writeln('没搜到《${command.value}》的结果');
      exit(0);
    }
    final exact = page.items.any((e) =>
        e.title.toLowerCase().replaceAll(' ', '') ==
        command.value.toLowerCase().replaceAll(' ', ''));
    if (exact) {
      stdout.writeln(
          '${command.value} · ${page.items.length} 条结果，显示前 ${command.limit} 条');
    } else {
      stdout.writeln(
          '没搜到精确匹配的《${command.value}》，以下是接近的结果'
          '（${page.items.length} 条，显示前 ${command.limit} 条）');
    }
    for (var i = 0; i < page.items.length; i++) {
      final item = page.items[i];
      stdout.writeln(
          '${(i + 1).toString().padLeft(2)}  ${item.title}  ID ${item.id}  ${item.episodeCount}集');
    }
    exit(0);
  } on AquaException catch (e) {
    stderr.writeln('搜索失败：${e.friendlyText}');
    exit(1);
  } catch (e) {
    stderr.writeln('搜索失败：$e');
    exit(1);
  }
}
