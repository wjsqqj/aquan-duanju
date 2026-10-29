import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../core/player/player_engine.dart';

/// 音轨 / 字幕轨选择面板。
///
/// 支持内嵌音轨、内嵌字幕、关闭字幕，以及从本地加载外挂字幕
/// （SRT / ASS / SSA / VTT / SUB）。外挂字幕在下次打开媒体时自动卸载，
/// 与 media_kit 的语义一致。
Future<void> showPlayerTracksSheet(
    BuildContext context, PlayerEngine engine) async {
  final tracks = engine.state.tracks;
  final audioTracks =
      tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
  final subtitleTracks = tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentAudio = engine.state.track.audio.id;
  final currentSubtitle = engine.state.track.subtitle.id;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const _SheetHeader('音轨'),
            if (audioTracks.isEmpty)
              const ListTile(title: Text('当前视频没有可选音轨'))
            else ...[
              ListTile(
                title: const Text('自动'),
                trailing:
                    currentAudio == 'auto' ? const Icon(Icons.check) : null,
                onTap: () {
                  engine.setAudioTrack(AudioTrack.auto());
                  Navigator.pop(sheetContext);
                },
              ),
              for (final track in audioTracks)
                ListTile(
                  title: Text(_trackLabel(
                      track.title, track.language, track.id, '音轨')),
                  subtitle: (track.codec ?? '').isEmpty
                      ? null
                      : Text(track.codec!),
                  trailing: track.id == currentAudio
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    engine.setAudioTrack(track);
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
            const Divider(height: 1),
            const _SheetHeader('字幕'),
            if (subtitleTracks.isEmpty)
              const ListTile(title: Text('当前视频没有内嵌字幕'))
            else ...[
              ListTile(
                title: const Text('自动'),
                trailing:
                    currentSubtitle == 'auto' ? const Icon(Icons.check) : null,
                onTap: () {
                  engine.setSubtitleTrack(SubtitleTrack.auto());
                  Navigator.pop(sheetContext);
                },
              ),
              for (final track in subtitleTracks)
                ListTile(
                  title: Text(_trackLabel(
                      track.title, track.language, track.id, '字幕')),
                  subtitle: (track.codec ?? '').isEmpty
                      ? null
                      : Text(track.codec!),
                  trailing: track.id == currentSubtitle
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    engine.setSubtitleTrack(track);
                    Navigator.pop(sheetContext);
                  },
                ),
              ListTile(
                title: const Text('关闭字幕'),
                trailing:
                    currentSubtitle == 'no' ? const Icon(Icons.check) : null,
                onTap: () {
                  engine.setSubtitleTrack(SubtitleTrack.no());
                  Navigator.pop(sheetContext);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('加载字幕文件…'),
              subtitle: const Text('支持 SRT / ASS / SSA / VTT / SUB'),
              onTap: () async {
                final file = await openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: '字幕',
                      extensions: ['srt', 'ass', 'ssa', 'vtt', 'sub'],
                    ),
                  ],
                );
                if (file == null) return;
                try {
                  await engine.setSubtitleTrack(
                    SubtitleTrack.uri(Uri.file(file.path).toString(),
                        title: file.name),
                  );
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                } catch (e) {
                  if (sheetContext.mounted) {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(content: Text('字幕加载失败：$e')));
                  }
                }
              },
            ),
          ],
        ),
      );
    },
  );
}

String _trackLabel(
    String? title, String? language, String id, String fallback) {
  final parts = <String>[];
  if (title != null && title.trim().isNotEmpty) parts.add(title.trim());
  if (language != null && language.trim().isNotEmpty) {
    parts.add(language.trim());
  }
  if (parts.isEmpty &&
      id.isNotEmpty &&
      id != 'auto' &&
      id != 'no') {
    parts.add('$fallback $id');
  }
  return parts.isEmpty ? fallback : parts.join(' · ');
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
