import 'dart:async';

import 'package:flutter/material.dart';

import '../core/aqua_error.dart';
import '../models/book.dart';
import '../models/manga.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';
import '../widgets/manga_image.dart';

/// 漫画阅读页：竖向连续看图 + 目录抽屉 + 上下话切换 + 进度记忆。
class MangaReaderScreen extends StatefulWidget {
  const MangaReaderScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.chapters,
    this.coverUrl = '',
    this.initialIndex = 0,
    this.restoreOffset = 0,
  });

  final String bookId;
  final String bookTitle;
  final String coverUrl;
  final List<BookChapter> chapters;
  final int initialIndex;

  /// 首次进入时还原到该话内的相对位置（0..1）。
  final double restoreOffset;

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen> {
  final _scroll = ScrollController();
  final _cache = <String, MangaChapterPages>{};

  late final ReadingProgressStore _store = AppScope.read(context).reading;
  late int _index = widget.initialIndex.clamp(0, _maxIndex);

  MangaChapterPages? _pages;
  Object? _error;
  bool _loading = true;
  bool _chrome = true;
  bool _restored = false;
  Timer? _saveTimer;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(_index, restore: widget.restoreOffset > 0);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    // ignore: discarded_futures
    _persist();
    super.dispose();
  }

  Future<void> _load(int index, {bool restore = false}) async {
    if (widget.chapters.isEmpty) return;
    final chapter = widget.chapters[index];
    final cached = _cache[chapter.id];
    setState(() {
      _index = index;
      _error = null;
      _pages = cached;
      _loading = cached == null;
    });
    if (cached != null) {
      _afterLoad(restore: restore);
      return;
    }
    try {
      final pages =
          await AppScope.read(context).api.chapterPages(chapter.id);
      _cache[chapter.id] = pages;
      if (!mounted || _index != index) return;
      setState(() {
        _pages = pages;
        _loading = false;
      });
      _afterLoad(restore: restore);
    } catch (e) {
      if (!mounted || _index != index) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _afterLoad({required bool restore}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (restore && !_restored) {
        _restored = true;
        _scroll.jumpTo((max * widget.restoreOffset).clamp(0.0, max));
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  double get _offsetRatio {
    if (!_scroll.hasClients) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.offset / max).clamp(0.0, 1.0);
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _persist);
  }

  Future<void> _persist() async {
    if (widget.chapters.isEmpty) return;
    final chapter = widget.chapters[_index];
    await _store.record(
      bookId: widget.bookId,
      title: widget.bookTitle,
      coverUrl: widget.coverUrl,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterIndex: _index,
      chapters: widget.chapters.length,
      offset: _offsetRatio,
      manga: true,
    );
  }

  Future<void> _go(int delta) async {
    final next = (_index + delta).clamp(0, _maxIndex);
    if (next == _index) return;
    await _persist();
    if (!mounted) return;
    await _load(next);
  }

  Future<void> _openDirectory() async {
    final picked = await showBookDirectorySheet(
      context,
      chapters: widget.chapters,
      currentIndex: _index,
      title: widget.bookTitle,
    );
    if (picked == null || picked == _index || !mounted) return;
    await _persist();
    if (!mounted) return;
    await _load(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _chrome = !_chrome),
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody()),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              top: _chrome ? 0 : -110,
              child: _buildTopBar(),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              bottom: _chrome ? 0 : -140,
              child: _buildBottomBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  _chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '目录',
                icon: const Icon(Icons.list_alt, color: Colors.white),
                onPressed: _openDirectory,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              TextButton(
                onPressed: _index > 0 ? () => _go(-1) : null,
                child: const Text('上一话',
                    style: TextStyle(color: Colors.white)),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_index + 1} / ${widget.chapters.length}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
              TextButton(
                onPressed: _index < _maxIndex ? () => _go(1) : null,
                child: const Text('下一话',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      final text = error is AquaException ? error.friendlyText : '图片加载失败';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 48, color: Colors.white38),
              const SizedBox(height: 12),
              Text(text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.tonal(
                      onPressed: () => _load(_index), child: const Text('重试')),
                  if (_index < _maxIndex)
                    TextButton(
                      onPressed: () => _go(1),
                      child: const Text('下一话',
                          style: TextStyle(color: Colors.white)),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final pages = _pages;
    if (pages == null || pages.isEmpty) {
      return const Center(
          child: Text('本话暂无图片', style: TextStyle(color: Colors.white70)));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: pages.pages.length + 1,
      itemBuilder: (context, i) {
        if (i == pages.pages.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: _index > 0 ? () => _go(-1) : null,
                  child: const Text('上一话',
                      style: TextStyle(color: Colors.white)),
                ),
                TextButton(
                  onPressed: _index < _maxIndex ? () => _go(1) : null,
                  child: const Text('下一话',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
        }
        final page = pages.pages[i];
        return MangaPageImage(
          url: page.url,
          keyHex: pages.key,
          aspectRatio: page.aspectRatio,
        );
      },
    );
  }
}
