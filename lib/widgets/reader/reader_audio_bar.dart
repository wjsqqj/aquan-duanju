import 'package:flutter/material.dart';

import '../../core/reader/reader_speech_controller.dart';
import '../../core/reader/speech/listen_format.dart';

/// 阅读页底部的听书控制条。
///
/// 只做控制，不负责状态：状态都在全局 [ReaderSpeechController] 里，
/// 由调用方用 `ListenableBuilder` 订阅后重建。
///
/// 进度条拖动用**本地草稿**（`_dragMs`）：拖动时不通知 controller，
/// 避免整页正文跟着每一帧重建；松手才 seek。
class ReaderAudioBar extends StatefulWidget {
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
  State<ReaderAudioBar> createState() => _ReaderAudioBarState();
}

class _ReaderAudioBarState extends State<ReaderAudioBar> {
  /// 拖动中的预览位置（毫秒；null = 没在拖）。拖动**不**碰 controller。
  int? _dragMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final chapter = controller.currentChapter;
    final total = controller.chapters.length;
    final index = total == 0 ? 0 : controller.chapterIndex + 1;
    final error = controller.errorText;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgress(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 6, 6),
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
                          // 优先级：错误 > 合成进度 > 章序号+剩余时间。
                          // 以前错误什么都不显示，用户只看到“点了没反应”。
                          error ??
                              controller.synthesisLabel ??
                              ReaderAudioBar.subtitleOf(
                                total,
                                index,
                                controller.remaining,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: error != null
                                ? theme.colorScheme.error
                                : (controller.synthesisLabel == null
                                      ? theme.colorScheme.outline
                                      : theme.colorScheme.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ToneButton(controller: controller),
                  _SpeedButton(controller: controller),
                  IconButton(
                    tooltip: '上一章',
                    onPressed: controller.chapterIndex <= 0
                        ? null
                        : controller.previous,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton.filled(
                    tooltip: error != null
                        ? '重试'
                        : (controller.playing ? '暂停' : '播放'),
                    onPressed: error != null
                        ? controller.retry
                        : (controller.loading ? null : controller.toggle),
                    icon: Icon(
                      error != null
                          ? Icons.refresh
                          : (controller.loading
                                ? Icons.hourglass_empty
                                : controller.playing
                                ? Icons.pause
                                : Icons.play_arrow),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一章',
                    onPressed: total == 0 || index >= total
                        ? null
                        : controller.next,
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    tooltip: '结束朗读',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一条细进度条：拖动只改本地草稿，松手才 seek（不重建正文）。
  Widget _buildProgress(BuildContext context) {
    final controller = widget.controller;
    final totalMs = controller.duration.inMilliseconds;
    final raw = _dragMs ?? controller.position.inMilliseconds;
    final shown = totalMs > 0 ? raw.clamp(0, totalMs) : 0;
    final enabled = totalMs > 0;
    return SizedBox(
      height: 22,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          value: enabled ? shown.toDouble() : 0,
          max: enabled ? totalMs.toDouble() : 1,
          // 总时长未知（音轨还没给 duration）时禁用：不给一个拖得动但没反应的控件。
          onChanged: enabled ? (v) => setState(() => _dragMs = v.round()) : null,
          onChangeEnd: enabled
              ? (v) async {
                  setState(() => _dragMs = null);
                  await controller.seekTo(Duration(milliseconds: v.round()));
                }
              : null,
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
    final error = controller.errorText;
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
              Icon(
                error != null ? Icons.error_outline : Icons.headphones,
                size: 18,
                color: error != null
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // 失败时把原因直接写在迷你条上：离开阅读页后这是唯一能看见的地方。
                  error ?? title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: error != null ? theme.colorScheme.error : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: error != null
                    ? '重试'
                    : (controller.playing ? '暂停' : '继续'),
                onPressed: error != null
                    ? controller.retry
                    : controller.toggle,
                icon: Icon(
                  error != null
                      ? Icons.refresh
                      : (controller.playing
                            ? Icons.pause
                            : Icons.play_arrow),
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
