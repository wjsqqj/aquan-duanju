import 'package:flutter/material.dart';

import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';
import 'manga_reader_screen.dart';
import 'reader_screen.dart';

/// 书籍详情：封面/简介/目录入口/继续阅读。
class BookDetailScreen extends StatefulWidget {
  const BookDetailScreen({
    super.key,
    required this.bookId,
    this.title = '',
    this.coverUrl = '',
    this.manga = false,
  });

  final String bookId;

  /// 漫画：用「话」计量并进入图片阅读器。
  final bool manga;

  /// 列表页带过来的标题与封面，加载期间先占位。
  final String title;
  final String coverUrl;

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  BookDetail? _detail;
  BookDirectory? _directory;
  Object? _error;
  bool _loading = true;
  bool _abstractExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      final results = await Future.wait<Object>([
        api.bookDetail(widget.bookId),
        api.bookDirectory(widget.bookId),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as BookDetail;
        _directory = results[1] as BookDirectory;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String get _title =>
      _detail?.title.isNotEmpty == true ? _detail!.title : widget.title;

  String get _cover =>
      _detail?.coverUrl.isNotEmpty == true ? _detail!.coverUrl : widget.coverUrl;

  ReadingEntry? get _progress =>
      AppScope.read(context).reading.entry(widget.bookId);

  /// 小说按「章」，漫画按「话」。
  String get _unit => widget.manga ? '话' : '章';

  void _openReader({int? chapterIndex}) {
    final directory = _directory;
    if (directory == null || directory.isEmpty) return;
    final progress = _progress;
    final index = (chapterIndex ?? progress?.chapterIndex ?? 0)
        .clamp(0, directory.chapters.length - 1);
    final restore = chapterIndex == null ? (progress?.offset ?? 0) : 0.0;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => widget.manga
          ? MangaReaderScreen(
              bookId: widget.bookId,
              bookTitle: _title,
              coverUrl: _cover,
              chapters: directory.chapters,
              initialIndex: index,
              restoreOffset: restore,
            )
          : ReaderScreen(
              bookId: widget.bookId,
              bookTitle: _title,
              coverUrl: _cover,
              chapters: directory.chapters,
              initialIndex: index,
              restoreOffset: restore,
            ),
    ));
  }

  Future<void> _showDirectory() async {
    final directory = _directory;
    if (directory == null) return;
    final picked = await showBookDirectorySheet(
      context,
      chapters: directory.chapters,
      currentIndex: _progress?.chapterIndex ?? -1,
      title: _title,
    );
    if (picked != null && mounted) _openReader(chapterIndex: picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书籍详情')),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: _buildContent(context),
      ),
      bottomNavigationBar: _loading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: () => _openReader(),
                  icon: const Icon(Icons.menu_book),
                  label: Text(_progress == null
                      ? '开始阅读'
                      : '继续阅读 · ${_progress!.chapterTitle}'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46)),
                ),
              ),
            ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final directory = _directory;
    final progress = _progress;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 104,
                height: 140,
                child: CoverImage(url: _cover),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    detail?.author.isNotEmpty == true
                        ? detail!.author
                        : '佚名',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (detail?.category.isNotEmpty == true)
                        _chip(context, detail!.category),
                      if (detail?.finished == true) _chip(context, '完结'),
                      if (detail?.score.isNotEmpty == true)
                        _chip(context, '评分 ${detail!.score}'),
                      if ((detail?.chapterCount ?? 0) > 0)
                        _chip(context, '${detail!.chapterCount} $_unit'),
                      if ((detail?.wordCount ?? 0) > 0)
                        _chip(context, _formatWords(detail!.wordCount)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.history,
                  color: theme.colorScheme.primary),
              title: Text('上次读到 · ${progress.chapterTitle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              // 漫画同样复用这条记录，只是章节标题是「第N话」。
              subtitle: LinearProgressIndicator(value: progress.percent),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openReader(),
            ),
          ),
        ],
        if ((detail?.abstractText ?? '').isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('简介',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            detail!.abstractText,
            maxLines: _abstractExpanded ? null : 4,
            overflow: _abstractExpanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _abstractExpanded = !_abstractExpanded),
              child: Text(_abstractExpanded ? '收起' : '展开'),
            ),
          ),
        ],
        if (directory != null && !directory.isEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text('目录',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(
                onPressed: _showDirectory,
                child: Text('全部 ${directory.total} $_unit'),
              ),
            ],
          ),
          for (final chapter in directory.chapters.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(chapter.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _openReader(chapterIndex: chapter.index),
            ),
        ],
      ],
    );
  }

  Widget _chip(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }

  String _formatWords(int words) {
    if (words >= 10000) return '${(words / 10000).toStringAsFixed(1)} 万字';
    return '$words 字';
  }
}
