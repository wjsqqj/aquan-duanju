import 'package:flutter/material.dart';

import '../models/book.dart';

/// 目录抽屉：支持搜索、定位当前章，返回选中的章节下标（取消返回 null）。
Future<int?> showBookDirectorySheet(
  BuildContext context, {
  required List<BookChapter> chapters,
  int currentIndex = -1,
  String title = '目录',
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _DirectorySheet(
      chapters: chapters,
      currentIndex: currentIndex,
      title: title,
    ),
  );
}

class _DirectorySheet extends StatefulWidget {
  const _DirectorySheet({
    required this.chapters,
    required this.currentIndex,
    required this.title,
  });

  final List<BookChapter> chapters;
  final int currentIndex;
  final String title;

  @override
  State<_DirectorySheet> createState() => _DirectorySheetState();
}

class _DirectorySheetState extends State<_DirectorySheet> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 打开时把当前章滚到视野内。
    if (widget.currentIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
  }

  void _scrollToCurrent() {
    if (!_scroll.hasClients) return;
    const itemHeight = 56.0;
    final target = (widget.currentIndex * itemHeight - 120).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.jumpTo(target);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim();
    final indices = <int>[
      for (var i = 0; i < widget.chapters.length; i++)
        if (query.isEmpty || widget.chapters[i].title.contains(query)) i,
    ];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(widget.title, style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('共 ${widget.chapters.length} 章',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索章节',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: indices.isEmpty
                ? Center(
                    child: Text('没有匹配的章节',
                        style: TextStyle(color: theme.colorScheme.outline)),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemCount: indices.length,
                    itemExtent: 56,
                    itemBuilder: (context, i) {
                      final index = indices[i];
                      final chapter = widget.chapters[index];
                      final selected = index == widget.currentIndex;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        title: Text(
                          chapter.volume.isEmpty
                              ? chapter.title
                              : '${chapter.volume} · ${chapter.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: selected
                              ? TextStyle(color: theme.colorScheme.primary)
                              : null,
                        ),
                        trailing: selected
                            ? Icon(Icons.play_arrow,
                                size: 18, color: theme.colorScheme.primary)
                            : null,
                        onTap: () => Navigator.of(context).pop(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
