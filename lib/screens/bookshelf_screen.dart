import 'package:flutter/material.dart';

import '../core/reading_sort.dart';
import '../widgets/common.dart';
import 'book_detail_screen.dart';

/// 书架：在读的小说与漫画，可继续、可移除、可排序。
class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  ReadingSort _sort = ReadingSort.recent;

  Future<void> _clearAll(BuildContext context) async {
    final scope = AppScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空书架？'),
        content: const Text('会移除全部阅读记录，离线缓存不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final entry in scope.reading.entries) {
      await scope.reading.remove(entry.bookId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          PopupMenuButton<ReadingSort>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            onSelected: (sort) => setState(() => _sort = sort),
            itemBuilder: (context) => [
              for (final sort in ReadingSort.values)
                PopupMenuItem(
                  value: sort,
                  child: Row(
                    children: [
                      if (sort == _sort)
                        const Icon(Icons.check, size: 16)
                      else
                        const SizedBox(width: 16),
                      const SizedBox(width: 8),
                      Text(readingSortLabel(sort)),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _clearAll(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: scope.reading,
        builder: (context, _) {
          final entries = sortReadingEntries(scope.reading.entries, _sort);
          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_outlined,
                      size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('读过的小说和漫画会出现在这里',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final entry = entries[i];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
                leading: SizedBox(
                  width: 52,
                  height: 70,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CoverImage(url: entry.coverUrl),
                  ),
                ),
                title: Text(entry.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${entry.manga ? '看到' : '读到'} · ${entry.chapterTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: entry.percent),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => scope.reading.remove(entry.bookId),
                ),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BookDetailScreen(
                    bookId: entry.bookId,
                    title: entry.title,
                    coverUrl: entry.coverUrl,
                    manga: entry.manga,
                  ),
                )),
              );
            },
          );
        },
      ),
    );
  }
}
