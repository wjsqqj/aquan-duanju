import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/aqua_error.dart';
import '../core/book_pager.dart';
import '../core/book_text.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';

/// 阅读主题：纸张 / 白底 / 夜间。
class _ReaderTheme {
  const _ReaderTheme(this.name, this.background, this.foreground);

  final String name;
  final Color background;
  final Color foreground;

  static const List<_ReaderTheme> all = [
    _ReaderTheme('纸张', Color(0xFFF6F1E4), Color(0xFF2E2A24)),
    _ReaderTheme('白底', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
    _ReaderTheme('夜间', Color(0xFF121212), Color(0xFFC9C6C0)),
  ];
}

/// 小说阅读页：滚动阅读 + 目录抽屉 + 字号/行距/主题 + 进度记忆。
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
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

  /// 首次进入时还原到该章内的相对位置（0..1）。
  final double restoreOffset;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  static const _fontKey = 'reader.fontSize';
  static const _lineKey = 'reader.lineHeight';
  static const _themeKey = 'reader.theme';
  // 阅读模式：0 滚动，1 翻页。
  static const _modeKey = 'reader.mode';

  final _scroll = ScrollController();
  final _cache = <String, List<String>>{};
  final _pageController = PageController();

  late final ReadingProgressStore _store = AppScope.read(context).reading;
  late final BookChapterCache _cacheStore = AppScope.read(context).bookCache;
  late int _index = widget.initialIndex.clamp(0, _maxIndex);

  List<String>? _paragraphs;

  /// 翻页模式下的页面文本。
  List<String>? _pages;
  int _currentPage = 0;

  Object? _error;
  bool _loading = true;
  bool _chrome = true;
  bool _restored = false;

  double _fontSize = 19;
  double _lineHeight = 1.8;
  int _themeIndex = 0;
  int _mode = 0;

  bool get _paged => _mode == 1;
  Timer? _saveTimer;
  SharedPreferences? _prefs;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  _ReaderTheme get _theme => _ReaderTheme.all[_themeIndex];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadPrefs();
    _load(_index, restore: widget.restoreOffset > 0);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _pageController.dispose();
    // 退出时补一次进度；dispose 里不能 await，直接丢出去。
    // ignore: discarded_futures
    _persist();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _fontSize = (prefs.getDouble(_fontKey) ?? 19).clamp(14.0, 30.0);
      _lineHeight = (prefs.getDouble(_lineKey) ?? 1.8).clamp(1.4, 2.4);
      _themeIndex = (prefs.getInt(_themeKey) ?? 0).clamp(0, 2);
      _mode = (prefs.getInt(_modeKey) ?? 0).clamp(0, 1);
    });
  }

  TextStyle _bodyStyle(_ReaderTheme theme) => TextStyle(
        color: theme.foreground,
        fontSize: _fontSize,
        height: _lineHeight,
      );

  /// 按当前屏幕与字号重算页面；只在翻页模式且有正文时才有意义。
  void _recomputePages() {
    final paragraphs = _paragraphs;
    if (!_paged || paragraphs == null) {
      _pages = null;
      return;
    }
    final size = MediaQuery.sizeOf(context);
    _pages = paginateParagraphs(
      paragraphs: paragraphs,
      style: _bodyStyle(_theme),
      width: size.width - 44,
      height: size.height - 150,
    );
  }

  Future<void> _setPref(void Function(SharedPreferences prefs) write) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    write(prefs);
  }

  Future<void> _load(int index, {bool restore = false}) async {
    if (widget.chapters.isEmpty) return;
    final chapter = widget.chapters[index];
    final cached = _cache[chapter.id];
    setState(() {
      _index = index;
      _error = null;
      _paragraphs = cached;
      _loading = cached == null;
    });
    if (cached != null) {
      _afterLoad(restore: restore);
      return;
    }
    try {
      final raw = await AppScope.read(context).api.chapterText(chapter.id);
      final paragraphs = htmlToParagraphs(raw);
      // 正文里常带一行章节标题，顶部已经显示了就不再重复。
      if (paragraphs.isNotEmpty && paragraphs.first == chapter.title) {
        paragraphs.removeAt(0);
      }
      _cache[chapter.id] = paragraphs;
      // 顺手把密文正文存起来，断网时还能读。
      await _cacheStore.put(chapter.id, raw);
      if (!mounted || _index != index) return;
      setState(() {
        _paragraphs = paragraphs;
        _loading = false;
      });
      _recomputePages();
      _afterLoad(restore: restore);
      _prefetch(index + 1);
    } catch (e) {
      if (!mounted || _index != index) return;
      // 网络不可用但有缓存：退化成本地阅读，不弹错误。
      final cached = _cacheStore.text(chapter.id);
      if (cached != null && cached.isNotEmpty) {
        final paragraphs = htmlToParagraphs(cached);
        _cache[chapter.id] = paragraphs;
        setState(() {
          _paragraphs = paragraphs;
          _loading = false;
        });
        _afterLoad(restore: restore);
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 后台把下一章也拉下来，翻页时基本无等待。
  void _prefetch(int index) {
    if (index < 0 || index > _maxIndex) return;
    final chapter = widget.chapters[index];
    if (_cache.containsKey(chapter.id)) return;
    // ignore: discarded_futures
    AppScope.read(context)
        .api
        .chapterText(chapter.id)
        .then((raw) {
          _cache[chapter.id] = htmlToParagraphs(raw);
        })
        .catchError((Object _) {});
  }

  void _afterLoad({required bool restore}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_paged) {
        final pages = _pages;
        if (pages == null) return;
        var target = 0;
        if (restore && !_restored) {
          _restored = true;
          target = (widget.restoreOffset * pages.length).round() - 1;
          if (target < 0) target = 0;
          if (target >= pages.length) target = pages.length - 1;
        }
        _currentPage = target;
        if (_pageController.hasClients) {
          _pageController.jumpToPage(target);
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

  double get _offsetRatio {
    if (_paged) {
      final pages = _pages;
      if (pages == null || pages.isEmpty) return 0;
      return ((_currentPage + 1) / pages.length).clamp(0.0, 1.0);
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

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('阅读设置',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('字号'),
                  const Spacer(),
                  IconButton(
                    onPressed: _fontSize <= 14
                        ? null
                        : () {
                            setSheetState(() => _fontSize -= 1);
                            setState(() {});
                            // ignore: discarded_futures
                            _setPref((p) => p.setDouble(_fontKey, _fontSize));
                            _recomputePages();
                          },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text(_fontSize.toStringAsFixed(0),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    onPressed: _fontSize >= 30
                        ? null
                        : () {
                            setSheetState(() => _fontSize += 1);
                            setState(() {});
                            // ignore: discarded_futures
                            _setPref((p) => p.setDouble(_fontKey, _fontSize));
                            _recomputePages();
                          },
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('模式'),
                  const Spacer(),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 0, label: Text('滚动')),
                      ButtonSegment(value: 1, label: Text('翻页')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (values) {
                      setSheetState(() => _mode = values.first);
                      setState(() {});
                      // ignore: discarded_futures
                      _setPref((p) => p.setInt(_modeKey, _mode));
                      _recomputePages();
                      _afterLoad(restore: false);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('行距'),
                  const Spacer(),
                  SegmentedButton<double>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1.6, label: Text('紧凑')),
                      ButtonSegment(value: 1.8, label: Text('标准')),
                      ButtonSegment(value: 2.1, label: Text('宽松')),
                    ],
                    selected: {
                      const [1.6, 1.8, 2.1].reduce((a, b) =>
                          (a - _lineHeight).abs() <= (b - _lineHeight).abs()
                              ? a
                              : b)
                    },
                    onSelectionChanged: (values) {
                      setSheetState(() => _lineHeight = values.first);
                      setState(() {});
                      // ignore: discarded_futures
                      _setPref((p) => p.setDouble(_lineKey, _lineHeight));
                      _recomputePages();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('背景'),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < _ReaderTheme.all.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: ChoiceChip(
                        label: Text(_ReaderTheme.all[i].name),
                        selected: _themeIndex == i,
                        onSelected: (_) {
                          setSheetState(() => _themeIndex = i);
                          setState(() {});
                          // ignore: discarded_futures
                          _setPref((p) => p.setInt(_themeKey, i));
                          _recomputePages();
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    return Scaffold(
      backgroundColor: theme.background,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _chrome = !_chrome),
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody(theme)),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              top: _chrome ? 0 : -120,
              child: _buildTopBar(theme),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              bottom: _chrome ? 0 : -140,
              child: _buildBottomBar(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(_ReaderTheme theme) {
    return Material(
      color: theme.background.withValues(alpha: 0.96),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: theme.foreground),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  _chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: theme.foreground, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '目录',
                icon: Icon(Icons.list_alt, color: theme.foreground),
                onPressed: _openDirectory,
              ),
              IconButton(
                tooltip: '设置',
                icon: Icon(Icons.text_fields, color: theme.foreground),
                onPressed: _showSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(_ReaderTheme theme) {
    return Material(
      color: theme.background.withValues(alpha: 0.96),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              TextButton(
                onPressed: _index > 0 ? () => _go(-1) : null,
                child: const Text('上一章'),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _paged && (_pages?.length ?? 0) > 0
                        ? '${_currentPage + 1} / ${_pages!.length} 页'
                        : '${_index + 1} / ${widget.chapters.length}',
                    style: TextStyle(color: theme.foreground, fontSize: 12),
                  ),
                ),
              ),
              TextButton(
                onPressed: _index < _maxIndex ? () => _go(1) : null,
                child: const Text('下一章'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaged(_ReaderTheme theme, List<String> pages) {
    return SafeArea(
      bottom: false,
      child: PageView.builder(
        controller: _pageController,
        itemCount: pages.length,
        onPageChanged: (i) {
          setState(() => _currentPage = i);
          // ignore: discarded_futures
          _persist();
        },
        itemBuilder: (context, i) {
          if (i >= pages.length) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(22, 64, 22, 96),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (i == 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Text(
                      _chapter.title,
                      style: TextStyle(
                        color: theme.foreground,
                        fontSize: _fontSize + 4,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    pages[i],
                    style: _bodyStyle(theme),
                  ),
                ),
                Center(
                  child: Text(
                    '${i + 1} / ${pages.length}',
                    style: TextStyle(
                      color: theme.foreground.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(_ReaderTheme theme) {
    final pages = _pages;
    if (_paged && pages != null && !_loading && _error == null) {
      return _buildPaged(theme, pages);
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      final text = error is AquaException ? error.friendlyText : '正文加载失败';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 48, color: theme.foreground.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.foreground)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.tonal(
                      onPressed: () => _load(_index), child: const Text('重试')),
                  if (_index < _maxIndex)
                    TextButton(
                        onPressed: () => _go(1), child: const Text('下一章')),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final paragraphs = _paragraphs ?? const <String>[];
    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(22, 64, 22, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _chapter.title,
              style: TextStyle(
                color: theme.foreground,
                fontSize: _fontSize + 4,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            for (final paragraph in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  paragraph,
                  style: TextStyle(
                    color: theme.foreground,
                    fontSize: _fontSize,
                    height: _lineHeight,
                  ),
                ),
              ),
            if (paragraphs.isEmpty)
              Text('本章暂无正文',
                  style: TextStyle(color: theme.foreground.withValues(alpha: 0.6))),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _index > 0 ? () => _go(-1) : null,
                  child: const Text('上一章'),
                ),
                TextButton(
                  onPressed: _index < _maxIndex ? () => _go(1) : null,
                  child: const Text('下一章'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
