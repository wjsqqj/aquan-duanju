import 'package:flutter/material.dart';

import 'jelly/jelly_press.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/ui/app_gap.dart';
import '../screens/book_detail_screen.dart';
import '../store/stores.dart';
import '../theme/app_tokens.dart';
import 'common.dart';
import 'ui/app_card.dart';
import 'tv_focusable.dart';
import 'tv_scope.dart';

/// 「最近在读」横排：小说与漫画各看各的（[manga] 过滤域），
/// 发现页小说 tab 只显示小说、漫画 tab 只显示漫画——不与影视的「继续观看」混排。
///
/// [collapsed] 为真时只保留一条约 40dp 的标题栏；[onToggleCollapsed] 提供时
/// 标题行右侧出现收起/展开按钮。不传这两个参数时行为与旧版完全一致。
class ReadingRail extends StatelessWidget {
  const ReadingRail({
    super.key,
    this.manga = false,
    this.collapsed = false,
    this.onToggleCollapsed,
  });

  /// true = 只显示漫画；false = 只显示小说。
  final bool manga;

  /// true = 折叠成一条标题栏（不渲染卡片）。
  final bool collapsed;

  /// 收起/展开回调；null 表示不显示按钮。
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.reading,
      builder: (context, _) {
        final entries = scope.reading.entries
            .where((e) => e.manga == manga)
            .take(10)
            .toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  child: Row(
                    children: [
                      const Text('最近在读',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      if (collapsed) ...[
                        AppGap.h(AppGapSize.s8),
                        Text('共${entries.length}本',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ],
                      const Spacer(),
                      if (onToggleCollapsed != null)
                        IconButton(
                          tooltip: collapsed ? '展开最近在读' : '收起最近在读',
                          onPressed: onToggleCollapsed,
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            collapsed
                                ? AppIcons.expand
                                : Icons.keyboard_arrow_up,
                            size: 20,
                          ),
                        )
                      else
                        AppGap.h(AppGapSize.s12),
                    ],
                  ),
                ),
                if (!collapsed) ...[
                  AppGap.v(AppGapSize.s8),
                  SizedBox(
                    height: 214,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final e in entries) _ReadingCard(entry: e),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({required this.entry});

  final ReadingEntry entry;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    // 电视上必须可聚焦：GestureDetector 收不到遥控器确定键。AppCard 的
    // 四态交互不覆盖 TV 焦点，所以外壳仍是 TvFocusable，卡片本身静态。
    return TvFocusable(
      enabled: TvScope.isTvOf(context),
      onTap: () => openBook(context, entry),
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: EdgeInsets.only(right: tokens.metrics.s12),
          child: JellyPress(
      strength: 0.03,
      child: AppCard.cover(
            image: CoverImage(url: entry.coverUrl),
            title: entry.title,
            subtitle: entry.chapterTitle,
            titleMaxLines: 1,
            badge: entry.manga ? '漫画' : '小说',
          )
    ),
        ),
      ),
    );
  }
}
