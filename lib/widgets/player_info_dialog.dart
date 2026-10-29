import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/player/player_engine.dart';

/// 播放信息弹窗的数据。
class PlayerInfoData {
  const PlayerInfoData({
    required this.engine,
    required this.title,
    required this.episodeLabel,
    this.quality,
    this.url,
    this.engineVersion,
    this.hwdecCurrent,
  });

  final PlayerEngine engine;
  final String title;
  final String episodeLabel;
  final String? quality;
  final String? url;
  final String? engineVersion;
  final String? hwdecCurrent;
}

/// 展示当前播放的技术信息：分辨率、编码、硬解状态、音轨、缓冲、引擎版本。
Future<void> showPlayerInfoDialog(
    BuildContext context, PlayerInfoData data) async {
  final state = data.engine.state;
  final params = state.videoParams;
  final video = state.track.video;
  final audio = state.track.audio;
  final hardware = (data.hwdecCurrent != null &&
          data.hwdecCurrent!.isNotEmpty &&
          data.hwdecCurrent != 'no') ||
      (params.hwPixelformat?.isNotEmpty ?? false);
  final width = params.w ?? state.width ?? 0;
  final height = params.h ?? state.height ?? 0;
  final host = data.url == null ? null : Uri.tryParse(data.url!)?.host;

  final rows = <String, String>{
    '影片': data.title,
    '分集': data.episodeLabel,
    '清晰度': data.quality ?? '-',
    '分辨率': '$width×$height',
    '视频编码': video.codec ?? params.pixelformat ?? '-',
    '解码': hardware
        ? '硬件解码'
            '${data.hwdecCurrent == null ? '' : '（${data.hwdecCurrent}）'}'
            '${params.hwPixelformat == null ? '' : ' / ${params.hwPixelformat}'}'
        : '软件解码',
    '音频': _join([audio.title, audio.language, audio.codec]),
    '缓冲': '${state.buffer.inSeconds} 秒',
    '引擎': data.engineVersion ?? '-',
    '来源': host == null || host.isEmpty ? '本地缓存' : host,
  };
  final text = rows.entries.map((e) => '${e.key}: ${e.value}').join('\n');

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          const Text('播放信息'),
          const Spacer(),
          IconButton(
            tooltip: '复制',
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('播放信息已复制')));
              }
            },
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 420),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in rows.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 76,
                        child: Text(entry.key,
                            style: Theme.of(dialogContext)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: Theme.of(dialogContext)
                                        .colorScheme
                                        .outline)),
                      ),
                      Expanded(
                        child: SelectableText(entry.value,
                            style: Theme.of(dialogContext).textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

String _join(List<String?> parts) {
  final values = [
    for (final part in parts)
      if (part != null && part.trim().isNotEmpty) part.trim(),
  ];
  return values.isEmpty ? '-' : values.join(' · ');
}
