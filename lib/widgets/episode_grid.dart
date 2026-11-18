import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';

/// 选集网格：当前集高亮、已看完打勾、离线角标，打开时把当前集滚到中间。
///
/// 从 `episode_picker.dart` 抽出来供两处复用：底部选集抽屉（点击控制栏 / E 键）
/// 与全屏右侧边缘抽屉（鼠标靠边呼出）。定位公式与行为必须完全一致，
/// 否则同一集在两个入口会落在不同位置。
///
/// 长剧分段（A4）：单季集数 > 100 时网格顶部渲染「1-100 / 101-200 / …」段
/// chips（样式基因复用 [SeasonChips]），默认段 = 当前集下标 `~/ 100`；点段
/// 只切换显示范围，不动数据源、打勾与高亮逻辑。段超出已加载列表时回调
/// [onRequireRange]，由调用方连续拉取直到覆盖该段尾。
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onSelect,
    this.watchedEpisodes = const <int>{},
    this.isDownloaded,
    this.totalEpisodes,
    this.onRequireRange,
  });

  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// 已看完的集号（[Episode.number]，从 1 开始）。
  final Set<int> watchedEpisodes;

  /// 该集是否已离线缓存（右上角角标）。
  final bool Function(Episode episode)? isDownloaded;

  /// 当前浏览季的元数据总集数（[Season.episodeCount]）。
  ///
  /// 段数按它与已加载列表长度的较大值算；未传或 ≤0 时按已加载列表。
  /// 分页源（列表可能只是第一页）传元数据值才能看到未加载的段。
  final int? totalEpisodes;

  /// 点了尚未加载完的段：回调需要的最后一个集下标（0-based，含）。
  ///
  /// 调用方应连续拉取直到覆盖该下标（或没有更多）；不传则点未加载段
  /// 只切范围、不补数据。
  final ValueChanged<int>? onRequireRange;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid> {
  /// 与 [SliverGridDelegateWithMaxCrossAxisExtent] 的视觉参数一一对应，
  /// 用于估算列数与行高。
  static const double _maxCellExtent = 72;
  static const double _crossSpacing = 8;
  static const double _mainSpacing = 8;

  /// 分段大小（A4，与参考实现 EPISODES_PER_PART 一致）。
  static const int _segmentSize = 100;

  final ScrollController _scroll = ScrollController();

  /// 网格实际宽度：由 [LayoutBuilder] 在布局阶段写入，不触发 rebuild。
  double _gridWidth = 0;

  /// 用户点选的段；null = 还没点过（默认取当前集所在段）。
  int? _segment;

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

  /// 参与分段的总集数：元数据与已加载列表取较大者。
  int get _effectiveTotal =>
      math.max(widget.episodes.length, widget.totalEpisodes ?? 0);

  /// 分段总数；≤100 集返回 0（不渲染分段 UI）。
  int get _segmentCount {
    final total = _effectiveTotal;
    if (total <= _segmentSize) return 0;
    return (total + _segmentSize - 1) ~/ _segmentSize;
  }

  /// 当前生效的段：用户点过的优先，否则当前集所在段（越界数据夹回范围）。
  int get _effectiveSegment {
    final count = _segmentCount;
    if (count == 0) return 0;
    return (_segment ?? widget.currentIndex ~/ _segmentSize)
        .clamp(0, count - 1);
  }

  /// 当前段的显示范围 [start, end)（end 不含；只到已加载的集数）。
  /// 段整体未加载时返回空范围（等待 [EpisodeGrid.onRequireRange] 补数据）。
  (int, int) _viewRange() {
    final total = widget.episodes.length;
    final count = _segmentCount;
    if (count == 0) return (0, total);
    final start = _effectiveSegment * _segmentSize;
    final end = math.min(start + _segmentSize, total);
    return (start, math.max(start, end));
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

  static const double _aspect = 1.6;

  /// 让当前集所在行居中的目标偏移（未 clamp）。
  /// 行号按**当前段内的局部下标**算，否则跨段偏移会把目标算出几千像素。
  double _targetOffset(double viewportHeight) {
    final (start, end) = _viewRange();
    final local = (_current - start).clamp(0, math.max(0, end - start - 1));
    final row = local ~/ _columns();
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

  /// 点段：切显示范围；段尾超出已加载时请求补数据；回到该段开头。
  void _selectSegment(int seg) {
    if (seg == _effectiveSegment) return;
    setState(() => _segment = seg);
    final endExclusive = math.min((seg + 1) * _segmentSize, _effectiveTotal);
    if (endExclusive > widget.episodes.length) {
      widget.onRequireRange?.call(endExclusive - 1);
    }
    // 当前集居中只在打开时做一次；点段回到该段顶部。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && _scroll.offset != 0) {
        _scroll.jumpTo(0);
      }
    });
  }

  /// 段 chips 行；无分段（≤100 集）返回 null（零视觉变化）。
  Widget? _buildSegmentChips(BuildContext context) {
    final count = _segmentCount;
    if (count == 0) return null;
    final tokens = context.app;
    final m = tokens.metrics;
    return Padding(
      padding: EdgeInsets.only(bottom: m.s12),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          // 桌面端默认 ScrollBehavior 不把鼠标算进拖拽设备，段多时拖不动。
          dragDevices: const <PointerDeviceKind>{
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.trackpad,
          },
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: m.s8,
            children: <Widget>[
              for (var seg = 0; seg < count; seg++)
                _SegmentChip(
                  label:
                      '${seg * _segmentSize + 1}-${math.min((seg + 1) * _segmentSize, _effectiveTotal)}',
                  selected: seg == _effectiveSegment,
                  onTap: () => _selectSegment(seg),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final (start, end) = _viewRange();
    return GridView.builder(
      controller: _scroll,
      shrinkWrap: true,
      itemCount: end - start,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _maxCellExtent,
        mainAxisSpacing: _mainSpacing,
        crossAxisSpacing: _crossSpacing,
        childAspectRatio: _aspect,
      ),
      itemBuilder: (context, i) {
        final index = start + i;
        final current = index == widget.currentIndex;
        final ep = widget.episodes[index];
        final label =
            ep.title.trim().isNotEmpty ? ep.title.trim() : '${index + 1}';
        return _EpisodeCell(
          label: label,
          current: current,
          locked: !ep.playable,
          downloaded: widget.isDownloaded?.call(ep) ?? false,
          watched: widget.watchedEpisodes.contains(ep.number),
          onTap: () => widget.onSelect(index),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 只记录宽度供定位公式使用，不做 setState。
        _gridWidth = constraints.maxWidth;
        final chips = _buildSegmentChips(context);
        if (chips == null) return _buildGrid(context);
        // 分段时 chips 固定在网格顶部：高度有界的外层（底部 sheet 的
        // Flexible / 全屏抽屉的 Expanded）用 Flexible 让网格吃剩余高度、
        // 内容超出才滚动、内容不足按内容收缩（与 ≤100 集的紧凑观感一致）。
        // 无界高度不能挂 flex（shrinkWrap 网格自己收缩）。
        if (!constraints.maxHeight.isFinite) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [chips, _buildGrid(context)],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [chips, Flexible(child: _buildGrid(context))],
        );
      },
    );
  }
}

/// 段 chip：样式基因与 `_SeasonChip`（season_chips.dart）一致。
class _SegmentChip extends StatelessWidget {
  const _SegmentChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = context.app.metrics;
    final colors = context.app.colors;
    return Material(
      color: selected ? colors.brand : colors.surface2,
      borderRadius: BorderRadius.all(Radius.circular(m.radiusSm)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.all(Radius.circular(m.radiusSm)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(m.s12, m.s6, m.s12, m.s6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: selected ? colors.onBrand : colors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
          ),
        ),
      ),
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
