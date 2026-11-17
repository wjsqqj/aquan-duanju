import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_metrics.dart';

/// 选集网格：当前集高亮、已看完打勾、离线角标，打开时把当前集滚到中间。
///
/// 从 `episode_picker.dart` 抽出来供两处复用：底部选集抽屉（点击控制栏 / E 键）
/// 与全屏右侧边缘抽屉（鼠标靠边呼出）。定位公式与行为必须完全一致，
/// 否则同一集在两个入口会落在不同位置。
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onSelect,
    this.watchedEpisodes = const <int>{},
    this.isDownloaded,
  });

  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// 已看完的集号（[Episode.number]，从 1 开始）。
  final Set<int> watchedEpisodes;

  /// 该集是否已离线缓存（右上角角标）。
  final bool Function(Episode episode)? isDownloaded;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid> {
  /// 与 [SliverGridDelegateWithMaxCrossAxisExtent] 的视觉参数一一对应，
  /// 用于估算列数与行高。
  static const double _maxCellExtent = 72;
  static const double _crossSpacing = 8;
  static const double _mainSpacing = 8;
  static const double _aspect = 1.6;

  final ScrollController _scroll = ScrollController();

  /// 网格实际宽度：由 [LayoutBuilder] 在布局阶段写入，不触发 rebuild。
  double _gridWidth = 0;

  @override
  void initState() {
    super.initState();
    // 打开时定位当前集；第 1 集保持顶部，不滚动。
    if (widget.currentIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 当前集下标的安全值：数据异常（越界 / 空列表）时不让面板滚到很远处。
  int get _current {
    if (widget.episodes.isEmpty) return 0;
    return widget.currentIndex.clamp(0, widget.episodes.length - 1);
  }

  int _columns() {
    final cols = (_gridWidth / (_maxCellExtent + _crossSpacing)).ceil();
    return cols < 1 ? 1 : cols;
  }

  double _rowExtent() {
    final cols = _columns();
    final usable = _gridWidth - _crossSpacing * (cols - 1);
    return usable / cols / _aspect + _mainSpacing;
  }

  /// 让当前集所在行居中的目标偏移（未 clamp）。
  double _targetOffset(double viewportHeight) {
    final row = _current ~/ _columns();
    return row * _rowExtent() - (viewportHeight - _rowExtent()) / 2;
  }

  void _scrollToCurrent() {
    if (!mounted || !_scroll.hasClients || _gridWidth <= 0) return;
    final pos = _scroll.position;
    // 只定位一次：bottom sheet 的入场动画只改纵向位移、不改视口高度，
    // 首帧后的 maxScrollExtent 已稳定；反复重试反而会在末尾把用户滚动抢回去。
    final target =
        _targetOffset(pos.viewportDimension).clamp(0.0, pos.maxScrollExtent);
    if (target > 0) _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 只记录宽度供定位公式使用，不做 setState。
        _gridWidth = constraints.maxWidth;
        return GridView.builder(
          controller: _scroll,
          shrinkWrap: true,
          itemCount: widget.episodes.length,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _maxCellExtent,
            mainAxisSpacing: _mainSpacing,
            crossAxisSpacing: _crossSpacing,
            childAspectRatio: _aspect,
          ),
          itemBuilder: (context, i) {
            final current = i == widget.currentIndex;
            final ep = widget.episodes[i];
            final label =
                ep.title.trim().isNotEmpty ? ep.title.trim() : '${i + 1}';
            return _EpisodeCell(
              label: label,
              current: current,
              locked: !ep.playable,
              downloaded: widget.isDownloaded?.call(ep) ?? false,
              watched: widget.watchedEpisodes.contains(ep.number),
              onTap: () => widget.onSelect(i),
            );
          },
        );
      },
    );
  }
}

class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.label,
    required this.current,
    required this.locked,
    required this.downloaded,
    required this.watched,
    required this.onTap,
  });

  final String label;
  final bool current;
  final bool locked;
  final bool downloaded;

  /// 已看完（整集播完）——右下角打勾。
  final bool watched;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: current
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radiusSm)),
      child: InkWell(
        onTap: locked ? null : onTap,
        borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radiusSm)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: current
                    ? theme.colorScheme.onPrimary
                    : (locked ? theme.colorScheme.outline : null),
                fontWeight: current ? FontWeight.bold : null,
              ),
            ),
            if (downloaded)
              Positioned(
                right: 3,
                top: 3,
                child: Icon(Icons.download_done,
                    size: 13,
                    color: current
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary),
              ),
            // 已看完：右下角打勾（与右上角的离线缓存角标错开）。
            if (watched)
              Positioned(
                right: 3,
                bottom: 3,
                child: Icon(Icons.check_rounded,
                    size: 13,
                    semanticLabel: '已看完',
                    color: current
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary),
              ),
          ],
        ),
      ),
    );
  }
}
