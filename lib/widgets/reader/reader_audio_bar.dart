import 'package:flutter/material.dart';

import '../../core/reader/reader_speech_controller.dart';
import '../../core/reader/speech/listen_format.dart';

/// 阅读页底部的听书控制条。
///
/// 只做控制，不负责状态：状态都在全局 [ReaderSpeechController] 里，
/// 由调用方用 `ListenableBuilder` 订阅后重建。
class ReaderAudioBar extends StatelessWidget {
  const ReaderAudioBar({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final ReaderSpeechController controller;
  final VoidCallback onClose;

  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  /// 副标题：`第 3 / 12 章 · 剩 12:34`；总时长未知时只显示章序号。
  static String subtitleOf(int total, int index, Duration? remaining) {
    final base = total == 0 ? '' : '第 $index / $total 章';
    if (remaining == null) return base;
    final rest = '剩 ${formatListenTime(remaining)}';
    return base.isEmpty ? rest : '$base · $rest';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapter = controller.currentChapter;
    final total = controller.chapters.length;
    final index = total == 0 ? 0 : controller.chapterIndex + 1;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chapter?.title ?? '朗读中',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      // 合成中优先显示块级进度：整章合成要十几秒，只转沙漏像卡死。
                      controller.synthesisLabel ??
                          ReaderAudioBar.subtitleOf(
                            total,
                            index,
                            controller.remaining,
                          ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: controller.synthesisLabel == null
                            ? theme.colorScheme.outline
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              _ToneButton(controller: controller),
              _SpeedButton(controller: controller),
              IconButton(
                tooltip: '上一章',
                onPressed: controller.previous,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton.filled(
                tooltip: controller.playing ? '暂停' : '播放',
                onPressed: controller.loading ? null : controller.toggle,
                icon: Icon(
                  controller.loading
                      ? Icons.hourglass_empty
                      : controller.playing
                          ? Icons.pause
                          : Icons.play_arrow,
                ),
              ),
              IconButton(
                tooltip: '下一章',
                onPressed: controller.next,
                icon: const Icon(Icons.skip_next),
              ),
              IconButton(
                tooltip: '结束朗读',
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全局迷你听书条：离开阅读页后仍能控制朗读（番茄式后台播放的入口）。
class MiniSpeechBar extends StatelessWidget {
  const MiniSpeechBar({super.key, required this.controller});

  final ReaderSpeechController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapter = controller.currentChapter;
    final title = controller.bookTitle.isEmpty
        ? '朗读中'
        : (chapter?.title.isNotEmpty == true
            ? '${controller.bookTitle} · ${chapter!.title}'
            : controller.bookTitle);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
          child: Row(
            children: [
              Icon(Icons.headphones, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: controller.playing ? '暂停' : '继续',
                onPressed: controller.toggle,
                icon: Icon(
                  controller.playing ? Icons.pause : Icons.play_arrow,
                  size: 20,
                ),
              ),
              IconButton(
                tooltip: '结束朗读',
                onPressed: controller.close,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音色切换。
class _ToneButton extends StatelessWidget {
  const _ToneButton({required this.controller});

  final ReaderSpeechController controller;

  @override
  Widget build(BuildContext context) {
    final tones = controller.tones?.tones ?? const [];
    if (tones.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      tooltip: '音色',
      icon: const Icon(Icons.record_voice_over_outlined),
      onSelected: controller.setToneById,
      itemBuilder: (context) => [
        for (final tone in tones)
          PopupMenuItem<int>(
            value: tone.id,
            child: Text(tone.title.isEmpty ? '音色 ${tone.id}' : tone.title),
          ),
      ],
    );
  }
}

/// 语速切换。
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.controller});

  final ReaderSpeechController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: '语速',
      icon: const Icon(Icons.speed),
      onSelected: controller.setSpeed,
      itemBuilder: (context) => [
        for (final speed in ReaderAudioBar._speeds)
          PopupMenuItem<double>(
            value: speed,
            child: Text('${speed.toStringAsFixed(2)}x'),
          ),
      ],
    );
  }
}
