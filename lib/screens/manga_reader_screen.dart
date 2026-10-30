import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/aqua_error.dart';
import '../core/manga_layout.dart';
import '../models/book.dart';
import '../models/manga.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';
import '../widgets/manga_image.dart';
import '../widgets/manga_zoom_page.dart';

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
  static const _spreadKey = 'manga.spread';

  final _scroll = ScrollController();
  final _spreadController = PageController();

  /// 双页模式下当前是第几组（横屏双页时用）。
  int _spreadIndex = 0;
  final _cache = <String, MangaChapterPages>{};

  late final ReadingProgressStore _store = AppScope.read(context).reading;
  late int _index = widget.initialIndex.clamp(0, _maxIndex);

  MangaChapterPages? _pages;
  Object? _error;
  bool _loading = true;
  bool _chrome = true;
  bool _restored = false;
  bool _spread = false;
  Timer? _saveTimer;
  SharedPreferences? _prefs;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  /// 当前窗口是否横向（宽 > 高）；双页拼版只在横屏生效。
  bool get _isLandscape {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  BookChapter get _chapter => widget.chapters[_index];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadPrefs();
    _load(_index, restore: widget.restoreOffset > 0);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _spread = prefs.getBool(_spreadKey) ?? false;
    });
  }

  /// 双击进全屏缩放：连续阅读的手势不受影响，放大只在浮层里做。
  void _openZoom(int index) {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MangaZoomPage(
        pages: pages.pages,
        keyHex: pages.key,
        initialIndex: index.clamp(0, pages.pages.length - 1),
      ),
    ));
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
              Text('漫画设置',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('横屏双页'),
                subtitle: Text(_spread && !_isLandscape
                    ? '当前窗口不是横屏，暂未生效'
                    : '横屏时把两页拼成一屏'),
                value: _spread,
                onChanged: (v) {
                  setSheetState(() => _spread = v);
                  setState(() {});
                  final prefs = _prefs;
                  if (prefs != null) {
                    // ignore: discarded_futures
                    prefs.setBool(_spreadKey, v);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _spreadController.dispose();
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
      _prefetchPages(cached, index);
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
      _prefetchPages(pages, index);
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
      final groups = _spreadGroups;
      if (groups != null) {
        var target = 0;
        if (restore && !_restored) {
          _restored = true;
          target = (widget.restoreOffset * groups.length)
              .floor()
              .clamp(0, groups.length - 1);
        }
        _spreadIndex = target;
        if (_spreadController.hasClients) {
          _spreadController.jumpToPage(target);
        }
        return;
      }
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

  /// 横屏双页时的分组；null 表示当前不是双页模式（竖向连续滚动）。
  List<List<int>>? get _spreadGroups {
    final pages = _pages;
    if (pages == null || pages.pages.isEmpty) return null;
    final size = MediaQuery.sizeOf(context);
    if (!useSpread(
        width: size.width, height: size.height, enabled: _spread)) {
      return null;
    }
    return spreadGroups(pages.pages.length);
  }

  double get _offsetRatio {
    final groups = _spreadGroups;
    if (groups != null && groups.isNotEmpty) {
      return ((_spreadIndex + 1) / groups.length).clamp(0.0, 1.0);
    }
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
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
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
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
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
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined, color: Colors.white),
                onPressed: _showSettings,
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
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
              TextButton(
                onPressed: _index > 0 ? () => _go(-1) : null,
                child: const Text('上一话',
                    style: TextStyle(color: Colors.white)),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _spreadGroups != null
                        ? '${_spreadIndex + 1} / ${_spreadGroups!.length} 组'
                        : '${_index + 1} / ${widget.chapters.length}',
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
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
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
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
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
    final groups = _spreadGroups;
    if (groups != null) {
      return _buildSpreadBody(pages, groups);
    }
    final screenCount = pages.pages.length;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: screenCount + 1,
      itemBuilder: (context, i) {
        if (i == screenCount) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
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
        return _pageWidget(pages, i);
      },
    );
  }

  /// 预取后续页：当前话的后 2 页 + 下一话的前 2 页，减少滑动时的白屏。
  ///
  /// [index] 是**章节**下标（不是页下标）：按 `skip(index+1)` 会让较后章节
  /// 跳过当前话的前几页，等于不预取。
  void _prefetchPages(MangaChapterPages pages, int index) {
    final api = AppScope.read(context).api;
    for (final page in pages.pages.skip(1).take(2)) {
      // ignore: discarded_futures
      precacheImage(MangaPageProvider(page.url, pages.key, api), context)
          .catchError((Object _) {});
    }
    final nextIndex = index + 1;
    if (nextIndex >= widget.chapters.length) return;
    final nextId = widget.chapters[nextIndex].id;
    final cached = _cache[nextId];
    if (cached != null) {
      for (final page in cached.pages.take(2)) {
        // ignore: discarded_futures
        precacheImage(MangaPageProvider(page.url, cached.key, api), context)
            .catchError((Object _) {});
      }
      return;
    }
    // ignore: discarded_futures
    _prefetchNextChapter(nextId);
  }

  /// 取下一话的页清单并预取前两页；失败不影响阅读。
  Future<void> _prefetchNextChapter(String chapterId) async {
    try {
      final api = AppScope.read(context).api;
      final next = await api.chapterPages(chapterId);
      if (!mounted) return;
      _cache[chapterId] = next;
      for (final page in next.pages.take(2)) {
        await precacheImage(
            MangaPageProvider(page.url, next.key, api), context);
      }
    } catch (_) {
      // 预取失败静默。
    }
  }

  /// 横屏双页：横向翻页，每屏一组（两页并排，末页落单）。
  Widget _buildSpreadBody(MangaChapterPages pages, List<List<int>> groups) {
    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis != Axis.horizontal) return false;
        if (n.direction == ScrollDirection.reverse &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 1) {
          _hint('已经是最后一组了，下一话在底栏切换');
        } else if (n.direction == ScrollDirection.forward &&
            n.metrics.pixels <= 1) {
          _hint('已经是最前面一组了');
        }
        return false;
      },
      child: PageView.builder(
      controller: _spreadController,
      itemCount: groups.length,
      onPageChanged: (i) {
        setState(() => _spreadIndex = i);
        // ignore: discarded_futures
        _persist();
      },
      itemBuilder: (context, i) {
        final group = groups[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 键盘翻组：← / →（仅横屏双页模式生效）。
            Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: const SizedBox.shrink(),
            ),
            for (final pageIndex in group)
              Expanded(child: _pageWidget(pages, pageIndex)),
          ],
        );
      },
      ),
    );
  }

  /// 键盘翻组：双页模式下 ← / → 翻上一页组 / 下一页组。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final groups = _spreadGroups;
    if (groups == null || groups.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _spreadController.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _spreadController.previousPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 轻提示（双页翻到边界时说明下一步）。
  void _hint(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 1),
    ));
  }

  /// 一页；双击进入全屏缩放。
  Widget _pageWidget(MangaChapterPages pages, int index) {
    final page = pages.pages[index];
    return GestureDetector(
      onDoubleTap: () => _openZoom(index),
      child: MangaPageImage(
        url: page.url,
        keyHex: pages.key,
        aspectRatio: page.aspectRatio,
      ),
    );
  }
}
