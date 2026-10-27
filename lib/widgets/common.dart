import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/aqua_error.dart';
import '../models/models.dart';
import '../store/stores.dart';

/// 全局单例容器： stores / api 在这里下发（无第三方状态管理依赖）。

class AppScope extends InheritedNotifier<ChangeNotifier> {
  const AppScope({
    super.key,
    required super.notifier,
    required this.api,
    required this.settings,
    required this.history,
    required this.follows,
    required super.child,
  });

  final AquaApi api;
  final SettingsStore settings;
  final HistoryStore history;
  final FollowStore follows;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// 不依赖通知的读取（回调里用）。
  static AppScope read(BuildContext context) {
    final widget = context
        .getElementForInheritedWidgetOfExactType<AppScope>()
        ?.widget;
    if (widget is AppScope) return widget;
    return of(context);
  }
}

/// 统一的三态内容视图：加载骨架 / 错误重试 / 内容。
class LoadView extends StatelessWidget {
  const LoadView({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.child,
    this.empty = false,
    this.emptyText = '这里空空如也',
  });

  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final Widget child;
  final bool empty;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonGrid();
    if (error != null) {
      return ErrorRetryView(
        error: error!,
        onRetry: onRetry,
      );
    }
    if (empty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(emptyText,
                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
    }
    return child;
  }
}

/// 错误态：翻译 AquaException，给「重试」。
class ErrorRetryView extends StatelessWidget {
  const ErrorRetryView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final text = error is AquaException
        ? (error as AquaException).friendlyText
        : '出了点小问题，请稍后再试';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton.tonal(
              onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 骨架屏（双列卡片网格的加载占位）。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.columns = 2});

  final int columns;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 0.62,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: 12,
      itemBuilder: (_, _) => Container(
        decoration: BoxDecoration(
          color: base.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

/// 剧集卡片：封面（竖版）+ 标题 + 副行（集数/热度/状态）。
class SeriesCard extends StatelessWidget {
  const SeriesCard({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
    this.badge,
  });

  final SeriesSummary item;
  final VoidCallback onTap;
  final String? subtitle;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = subtitle ??
        (item.episodeCount > 0 ? '共${item.episodeCount}集' : item.category);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CoverImage(url: item.coverUrl),
                ),
                if (badge != null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          color: theme.colorScheme.onPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 封面图：缓存 + 占位 + 失效兜底（封面 URL 有签名过期时间，过期返回 403）。
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.url, this.fit = BoxFit.cover});

  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.movie_outlined,
            color: Theme.of(context).colorScheme.outline),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, _) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      errorWidget: (_, _, _) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

/// 双列剧集瀑布网格（自带滚动控制器与加载更多回调）。
class SeriesGrid extends StatelessWidget {
  const SeriesGrid({
    super.key,
    required this.items,
    required this.onTap,
    this.hasMore = false,
    this.onLoadMore,
    this.header,
    this.columns,
  });

  final List<SeriesSummary> items;
  final void Function(SeriesSummary item) onTap;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final Widget? header;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = columns ??
        (width >= 1100 ? 6 : width >= 800 ? 4 : width >= 560 ? 3 : 2);
    final childCount = items.length + (hasMore ? cols : 0) + (header != null ? 1 : 0);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.62,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
      ),
      itemCount: childCount,
      itemBuilder: (context, index) {
        if (header != null && index == 0) return header!;
        final i = index - (header != null ? 1 : 0);
        if (i >= items.length) {
          // 触底加载更多。
          if (hasMore && onLoadMore != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => onLoadMore!());
          }
          return const Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final item = items[i];
        return SeriesCard(item: item, onTap: () => onTap(item));
      },
    );
  }
}

/// 把热度/播放数格式化成「4102万热度」。
String formatCount(int n) {
  if (n >= 100000000) {
    final v = n / 100000000;
    return '${_trim(v)}亿';
  }
  if (n >= 10000) {
    final v = n / 10000;
    return '${_trim(v)}万';
  }
  return '$n';
}

String _trim(double v) {
  if (v >= 100) return v.toStringAsFixed(0);
  if (v >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
}

/// 数字转中文序数（1→第1集，直接用数字即可）。
String episodeLabel(int n) => '第$n集';

/// 随机工具：洗牌（对 RangeError 免疫）。
void shuffleList<T>(List<T> list, {math.Random? rng}) => list.shuffle(rng);
