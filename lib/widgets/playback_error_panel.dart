import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/playback_diagnostics.dart';
import '../core/playback_failure.dart';

/// 播放失败面板。
///
/// 默认只显示友好文案与「重试 / 返回」；「详情」渐进披露原始错误、脱敏
/// 地址与最近 40 条引擎日志，「复制诊断」把脱敏文本写入剪贴板。对用户
/// 不制造噪音，对排查保留完整证据。
class PlaybackErrorPanel extends StatefulWidget {
  const PlaybackErrorPanel({
    super.key,
    required this.failure,
    required this.rawError,
    required this.logs,
    required this.onRetry,
    required this.onBack,
    this.url,
    this.seriesTitle,
    this.episodeNumber,
    this.episodeTitle,
    this.quality,
  });

  final PlaybackFailure failure;
  final String? rawError;
  final String? url;
  final List<String> logs;
  final String? seriesTitle;
  final int? episodeNumber;
  final String? episodeTitle;
  final String? quality;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  State<PlaybackErrorPanel> createState() => _PlaybackErrorPanelState();
}

class _PlaybackErrorPanelState extends State<PlaybackErrorPanel> {
  bool _expanded = false;

  Future<void> _copyDiagnostics() async {
    final text = buildPlaybackDiagnosticText(
      rawError: widget.rawError,
      engineLogs: widget.logs,
      url: widget.url,
      title: widget.seriesTitle,
      episodeNumber: widget.episodeNumber,
      episodeTitle: widget.episodeTitle,
      quality: widget.quality,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('诊断信息已复制'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 500),
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.45)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.redAccent,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.failure.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: widget.onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                  ),
                  OutlinedButton(
                    onPressed: widget.onBack,
                    child: const Text(
                      '返回',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: Colors.white54,
                    ),
                    label: const Text(
                      '详情',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _copyDiagnostics,
                    icon: const Icon(
                      Icons.copy_rounded,
                      size: 18,
                      color: Colors.white54,
                    ),
                    label: const Text(
                      '复制诊断',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? _buildDetails(context)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    final maskedUrl = widget.url == null ? null : maskSensitiveUrl(widget.url!);
    final logs = maskLogLines(
      widget.logs,
      rawUrl: widget.url,
      maskedUrl: maskedUrl,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow(
                label: '原始错误',
                value: (widget.rawError ?? '').trim().isEmpty
                    ? '(空)'
                    : maskDiagnosticText(
                        widget.rawError!,
                        rawUrl: widget.url,
                        maskedUrl: maskedUrl,
                      ),
              ),
              _DetailRow(label: '地址', value: maskedUrl ?? '(无)'),
              _DetailRow(
                label: '引擎日志（最近 ${logs.length} 条）',
                value: logs.isEmpty ? '(无)' : logs.join('\n'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(
            _wrapLongTokens(value),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  /// 长 token（URL / 哈希）插入零宽空格，避免撑破面板。
  String _wrapLongTokens(String value) => value
      .replaceAll('/', '/\u200B')
      .replaceAll('&', '&\u200B')
      .replaceAll('?', '?\u200B');
}
