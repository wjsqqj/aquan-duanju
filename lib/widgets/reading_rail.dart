import 'package:flutter/material.dart';

import '../screens/book_detail_screen.dart';
import '../store/stores.dart';
import 'common.dart';

/// 「最近在读」横排：小说与漫画共用一份阅读进度，点了直接回详情页续读。
///
/// 与发现页的「继续观看」分开：那边是短剧，这里只有书籍，互不干扰。
class ReadingRail extends StatelessWidget {
  const ReadingRail({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.reading,
      builder: (context, _) {
        final entries = scope.reading.entries.take(10).toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('最近在读',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 172,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final e in entries) _ReadingCard(entry: e),
                  ],
                ),
              ),
            ],
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
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => openBook(context, entry),
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 104,
                      height: 140,
                      child: CoverImage(url: entry.coverUrl),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        entry.manga ? '漫画' : '小说',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 2),
              Text(entry.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}
