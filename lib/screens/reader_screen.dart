import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/aqua_error.dart';
import '../core/reader/chinese_converter.dart';
import '../core/reader/reader_click_action.dart';
import '../core/reader/reader_page_metrics.dart';
import '../core/reader/reader_paginator.dart';
import '../core/reader/reader_settings.dart';
import '../core/reader/reader_theme.dart';
import '../core/reader/reader_typography.dart';
import '../widgets/continuous_chapters.dart';
import '../widgets/reader/reader_page_view.dart';
import '../widgets/reader/reader_pager.dart';
import '../widgets/reader/reader_settings_sheet.dart';
import 'book_audio_screen.dart';
import 'replace_rules_screen.dart';
import '../core/book_text.dart';
import '../core/reader/content_signature.dart';
import '../core/reader/replace_rules.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';
import '../widgets/reader/reader_click_zone_editor.dart';

/// 本章内搜索面板。
class _ChapterSearchSheet extends StatefulWidget {
  const _ChapterSearchSheet({
    required this.paragraphs,
    required this.onJump,
  });

  final List<String> paragraphs;

  /// 命中项在章内的字符偏移。
  final ValueChanged<int> onJump;

  @override
  State<_ChapterSearchSheet> createState() => _ChapterSearchSheetState();
}

class _ChapterSearchSheetState extends State<_ChapterSearchSheet> {
  static const int _maxHits = 100;

  final _controller = TextEditingController();
  List<_SearchHit> _hits = const <_SearchHit>[];
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String raw) {
    final query = raw.trim().toLowerCase();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() => _hits = const <_SearchHit>[]);
      return;
    }
    final hits = <_SearchHit>[];
    // 段落之间的分隔符算 1 个字符，与分页器的字符偏移口径一致。
    var paragraphStart = 0;
    for (var i = 0; i < widget.paragraphs.length; i++) {
      final text = widget.paragraphs[i];
      final lower = text.toLowerCase();
      var from = 0;
      while (hits.length < _maxHits) {
        final index = lower.indexOf(query, from);
        if (index < 0) break;
        final snippet = _snippet(text, index, query.length);
        hits.add(_SearchHit(
          paragraph: i,
          charOffset: paragraphStart + index,
          snippet: snippet.$1,
          snippetIndex: snippet.$2,
          matchLength: query.length,
        ));
        from = index + query.length;
      }
      paragraphStart += text.length + 1;
      if (hits.length >= _maxHits) break;
    }
    setState(() => _hits = hits);
  }

  /// 返回（片段, 命中词在片段里的下标）。
  static (String, int) _snippet(String text, int start, int length) {
    final from = (start - 12).clamp(0, text.length);
    final to = (start + length + 12).clamp(0, text.length);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < text.length ? '…' : '';
    return ('$prefix${text.substring(from, to)}$suffix',
        prefix.length + (start - from));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FractionallySizedBox(
      heightFactor: 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: '本章内查找',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    _hits.isEmpty ? '没有找到「$_query」' : '${_hits.length} 处命中',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _hits.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty ? '输入关键词开始查找' : '换个词试试',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    itemCount: _hits.length,
                    itemBuilder: (context, i) {
                      final hit = _hits[i];
                      return ListTile(
                        dense: true,
                        leading: Text(
                          '${hit.paragraph + 1}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                        title: _highlight(theme, hit),
                        onTap: () => widget.onJump(hit.charOffset),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 命中词加粗高亮。
  Widget _highlight(ThemeData theme, _SearchHit hit) {
    final base = theme.textTheme.bodyMedium;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: hit.snippet.substring(0, hit.snippetIndex)),
          TextSpan(
            text: hit.snippet.substring(
              hit.snippetIndex,
              (hit.snippetIndex + hit.matchLength).clamp(0, hit.snippet.length),
            ),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          TextSpan(
            text: hit.snippet.substring(
              (hit.snippetIndex + hit.matchLength).clamp(0, hit.snippet.length),
            ),
          ),
        ],
      ),
      style: base,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SearchHit {
  const _SearchHit({
    required this.paragraph,
    required this.charOffset,
    required this.snippet,
    required this.snippetIndex,
    required this.matchLength,
  });

  final int paragraph;
  final int charOffset;
  final String snippet;

  /// 命中词在 [snippet] 里的下标。
  final int snippetIndex;
  final int matchLength;
}

/// 书签与划线面板。
class _BookmarkSheet extends StatelessWidget {
  const _BookmarkSheet({
    required this.store,
    required this.markings,
    required this.bookId,
    required this.onJump,
  });

  final BookmarkStore store;
  final MarkingStore markings;
  final String bookId;

  /// 跳转到某章某字符位置。
  final Future<void> Function(int chapterIndex, int charOffset) onJump;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, markings]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final bookmarkList = store.of(bookId);
        final markingList = markings.of(bookId);
        if (bookmarkList.isEmpty && markingList.isEmpty) {
          return SizedBox(
            height: 220,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmarks_outlined,
                      size: 40, color: theme.colorScheme.outline),
                  const SizedBox(height: 10),
                  Text('还没有书签', style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    '长按正文选字可划线；九宫格「添加书签」可存位置',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          );
        }
        return FractionallySizedBox(
          heightFactor: 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text('书签与划线', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    Text(
                      '${bookmarkList.length} 书签 · ${markingList.length} 划线',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              const Divider(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (bookmarkList.isNotEmpty)
                      _sectionHeader(theme, '书签'),
                    for (final bookmark in bookmarkList)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.bookmark, size: 18),
                        title: Text(
                          bookmark.chapterTitle.isEmpty
                              ? '第 ${bookmark.chapterIndex + 1} 章'
                              : bookmark.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          bookmark.excerpt.isEmpty
                              ? '位置 ${bookmark.charOffset}'
                              : bookmark.excerpt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        onTap: () => onJump(
                            bookmark.chapterIndex, bookmark.charOffset),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => store.remove(bookId, bookmark.id),
                        ),
                      ),
                    if (markingList.isNotEmpty) _sectionHeader(theme, '划线'),
                    for (final marking in markingList)
                      ListTile(
                        dense: true,
                        leading: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: Color(marking.color.argb),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        title: Text(
                          marking.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          marking.chapterTitle.isEmpty
                              ? '第 ${marking.chapterIndex + 1} 章'
                              : marking.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        onTap: () => onJump(
                            marking.chapterIndex, marking.charStart),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => markings.remove(bookId, marking.id),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
}

/// 阅读主题：纸张 / 白底 / 夜间。
class _ReaderTheme {
  const _ReaderTheme(this.name, this.background, this.foreground);

  final String name;
  final Color background;
  final Color foreground;
}

/// 跨章加载完成后要落到的位置。
enum _ChapterLanding { keep, first, last }

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
    this.restoreCharOffset = -1,
  });

  final String bookId;
  final String bookTitle;
  final String coverUrl;
  final List<BookChapter> chapters;
  final int initialIndex;

  /// 首次进入时还原到该章内的相对位置（0..1）。
  final double restoreOffset;

  /// 章内字符偏移；`>= 0` 时优先于 [restoreOffset]。
  final int restoreCharOffset;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _cache = <String, List<String>>{};

  /// 自绘翻页容器：6 种动画与手势都在 [ReaderPager] 内部。
  final _pager = ReaderPagerController();

  late final ReadingProgressStore _store = AppScope.read(context).reading;
  late final BookChapterCache _cacheStore = AppScope.read(context).bookCache;
  late final BookmarkStore _bookmarks = AppScope.read(context).bookmarks;
  late final MarkingStore _markings = AppScope.read(context).markings;
  late final ReplaceRuleStore _replaceRules = AppScope.read(context).replaceRules;

  /// 九宫格动作与分区几何的唯一来源（S2 起排版设置也走这里）。
  late final ReaderSettingsStore _settingsStore =
      AppScope.read(context).readerSettings;

  /// 连续阅读体控制器：滚动模式的「翻一屏」由它执行。
  final ContinuousChaptersController _continuous = ContinuousChaptersController();

  late int _index = widget.initialIndex.clamp(0, _maxIndex);

  /// 跨章后要落到首页还是末页（`_afterLoad` 消费一次）。
  _ChapterLanding _landing = _ChapterLanding.keep;

  List<String>? _paragraphs;

  /// 翻页模式的分页结果（含页码↔字符 offset 映射）。
  ReaderPagination? _pagination;

  /// 分页缓存键：章 / 排版 / 几何 / 简繁 任一变化都要重算。
  String _paginationKey = '';

  /// 简繁转换后的段落缓存。
  List<String>? _converted;
  String _convertedKey = '';

  int _currentPage = 0;

  /// 章节原文缓存：替换规则变了要用它重新派生段落，不再联网。
  final _rawCache = <String, String>{};

  Object? _error;
  bool _loading = true;
  bool _chrome = true;
  bool _restored = false;

  /// 正文就绪：加载完成前不写进度，避免把「空位置」落盘。
  bool _ready = false;

  /// 写入序号，只增不减：旧快照后到也不会覆盖新进度。
  int _persistSeq = 0;

  /// 状态栏「净化已生效」提示是否可见。
  bool _replaceHintShown = false;

  Timer? _autoTimer;

  /// 连续阅读时：当前章内比例与段落下标（用于进度与听书对齐）。
  double _continuousRatio = 0;
  int _paragraphIndex = 0;

  Timer? _saveTimer;

  /// 设置唯一来源。
  ReaderSettings get _settings => _settingsStore.value;

  ReaderTypography get _type => _settings.activeThemeConfig.typography;

  double get _fontSize => _type.fontSize;
  double get _lineHeight => _type.lineHeight;
  bool get _autoTurn => _settings.autoTurn;
  int get _autoInterval => _settings.autoIntervalSec;

  bool get _paged => _settings.mode == ReaderMode.paged;

  /// 双页并排是否生效：翻页模式 + 开关打开 + 屏幕够宽（窄屏自动退回单页）。
  bool get _spreadEnabled =>
      _paged && _settings.doublePage && MediaQuery.sizeOf(context).width >= 600;

  /// 单页下标 → 屏下标。
  int _spreadIndexOf(int page) => _spreadEnabled ? page ~/ 2 : page;

  /// 九宫格分区几何（跟随用户配置）。
  ClickZoneLayout get _clickLayout => _settings.zoneLayout;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  _ReaderTheme get _theme {
    final config = _settings.activeThemeConfig;
    final night = _settings.nightMode;
    return _ReaderTheme(
      config.name,
      Color(night ? config.backgroundColorNight : config.backgroundColor),
      Color(night ? config.textColorNight : config.textColor),
    );
  }

  /// 设置变化：作废分页/转换缓存、重排自动翻页、应用屏幕相关项。
  void _onSettingsChanged() {
    if (!mounted) return;
    _paginationKey = '';
    _convertedKey = '';
    _syncAutoTimer();
    _applyScreenSettings();
    setState(() {});
  }

  void _applyScreenSettings() {
    final settings = _settings;
    if (settings.keepAwake) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
    if (settings.brightness >= 0) {
      // Linux 等平台没有亮度插件，失败时不打断阅读。
      ScreenBrightness()
          .setApplicationScreenBrightness(settings.brightness)
          .catchError((_) {});
    } else {
      ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
    }
  }

  /// 批注/划线变化：重绘当前页（高亮跟随）。
  void _onAnnotationsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 首次进章节时提示一次「净化已生效」，避免用户以为正文被吞了。
  void _maybeToastReplace() {
    if (_replaceHintShown) return;
    final count = _replaceRules.forBook(widget.bookId).length;
    if (count == 0) return;
    _replaceHintShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _toast('已应用 $count 条正文净化规则');
    });
  }

  /// 替换规则变化：用原文重新派生段落，再重排。
  void _onReplaceRulesChanged() {
    if (!mounted) return;
    _cache.clear();
    _convertedKey = '';
    _paginationKey = '';
    final raw = _rawCache[_chapter.id];
    if (raw == null) {
      setState(() {});
      return;
    }
    final paragraphs = _deriveParagraphs(_chapter, raw);
    _cache[_chapter.id] = paragraphs;
    setState(() {
      _paragraphs = paragraphs;
      _replaceHintShown = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台/被遮挡时立刻落盘：系统可能在之后直接杀掉进程。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveTimer?.cancel();
      // ignore: discarded_futures
      _persist();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _settingsStore.addListener(_onSettingsChanged);
    _bookmarks.addListener(_onAnnotationsChanged);
    _markings.addListener(_onAnnotationsChanged);
    _replaceRules.addListener(_onReplaceRulesChanged);
    _syncAutoTimer();
    _applyScreenSettings();
    _load(
      _index,
      restore: widget.restoreOffset > 0 || widget.restoreCharOffset >= 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsStore.removeListener(_onSettingsChanged);
    _bookmarks.removeListener(_onAnnotationsChanged);
    _markings.removeListener(_onAnnotationsChanged);
    _replaceRules.removeListener(_onReplaceRulesChanged);
    _saveTimer?.cancel();
    _autoTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    WakelockPlus.disable();
    ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
    // 退出时补一次进度；dispose 里不能 await，直接丢出去。
    // ignore: discarded_futures
    _persist();
    super.dispose();
  }

  /// 翻到相邻页；返回是否真的翻动了（到边界返回 false，调用方据此换章）。
  bool _turnPage(int delta) {
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return false;
    final step = _spreadEnabled ? 2 : 1;
    final target =
        (_currentPage + delta * step).clamp(0, pagination.pageCount - 1);
    if (target == _currentPage) return false;
    _feedbackOnTurn();
    // ignore: discarded_futures
    _pager.goTo(_spreadIndexOf(target));
    return true;
  }

  /// 九宫格单击派发。`_chrome` 打开时任意点击先收菜单，避免误翻页。
  void _onTapUp(TapUpDetails details, Size size) {
    if (_chrome) {
      setState(() => _chrome = false);
      return;
    }
    final slot = _clickLayout.indexFor(details.localPosition, size);
    final action = _settingsStore.value.actionAt(slot);
    // ignore: discarded_futures
    _runAction(action);
  }

  Future<void> _runAction(ReaderClickAction action) async {
    switch (action) {
      case ReaderClickAction.none:
        return;
      case ReaderClickAction.menu:
        setState(() => _chrome = !_chrome);
        return;
      case ReaderClickAction.prevPage:
        await _stepPage(-1);
        return;
      case ReaderClickAction.nextPage:
        await _stepPage(1);
        return;
      case ReaderClickAction.prevChapter:
        await _go(-1, landing: _ChapterLanding.last);
        return;
      case ReaderClickAction.nextChapter:
        await _go(1, landing: _ChapterLanding.first);
        return;
      case ReaderClickAction.prevParagraph:
      case ReaderClickAction.nextParagraph:
        // 没有逐段朗读队列时退化为翻页，保证点击有反馈。
        await _stepPage(action == ReaderClickAction.nextParagraph ? 1 : -1);
        return;
      case ReaderClickAction.directory:
        await _openDirectory();
        return;
      case ReaderClickAction.toggleSpeech:
        _openAudio();
        return;
      case ReaderClickAction.addBookmark:
        await _addBookmark();
        return;
      case ReaderClickAction.editContent:
      case ReaderClickAction.toggleReplace:
        await _openReplaceRules();
        return;
      case ReaderClickAction.searchContent:
        await _openSearchInChapter();
        return;
      case ReaderClickAction.syncProgress:
        _toast('「${action.label}」暂未支持');
        return;
    }
  }

  /// 本章内全文搜索：命中段落列出，点击跳到对应页。
  Future<void> _openSearchInChapter() async {
    final paragraphs = _displayParagraphs;
    if (paragraphs.isEmpty) {
      _toast('正文还没加载完');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => _ChapterSearchSheet(
        paragraphs: paragraphs,
        onJump: (offset) {
          Navigator.of(context).maybePop();
          _jumpToChar(offset);
        },
      ),
    );
  }

  /// 跳到章内某个字符位置。
  void _jumpToChar(int charOffset) {
    if (!_paged) {
      _continuous.jumpToTop();
      return;
    }
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return;
    final page = pagination.pageForChar(charOffset);
    setState(() => _currentPage = page);
    _pager.jumpTo(_spreadIndexOf(page));
  }

  /// 翻页反馈：轻触 + 可选点击音。所有翻页入口（点击/滑动/自动/按键）共用。
  void _feedbackOnTurn() {
    final settings = _settings;
    if (settings.hapticOnTurn) HapticFeedback.selectionClick();
    if (settings.soundOnTurn) SystemSound.play(SystemSoundType.click);
  }

  Future<void> _addBookmark() async {
    final offset = _currentCharOffset;
    if (offset < 0) {
      _toast('正文还在加载，稍后再试');
      return;
    }
    await _bookmarks.add(
      bookId: widget.bookId,
      chapterId: _chapter.id,
      chapterIndex: _index,
      charOffset: offset,
      chapterTitle: _chapter.title,
      excerpt: _excerptAt(offset),
    );
    if (!mounted) return;
    _toast('已加书签');
  }

  /// 划线：把选中文本在整章里的位置换算成字符区间。
  ///
  /// 选区文本取自 `SelectionArea`，跨行时带换行；这里按「去掉所有空白后」的
  /// 扁平串定位，再把扁平下标映射回原文下标，避免缩进/换行造成偏移。
  Future<void> _markSelection(String selectedText) async {
    final target = _stripSpaces(selectedText);
    if (target.isEmpty) return;
    final chapterText = _displayParagraphs.join('\n');
    if (chapterText.isEmpty) return;

    final flat = StringBuffer();
    final map = <int>[];
    for (var i = 0; i < chapterText.length; i++) {
      final ch = chapterText[i];
      if (_isSpace(ch)) continue;
      flat.write(ch);
      map.add(i);
    }
    final flatText = flat.toString();

    var found = flatText.indexOf(target);
    var length = target.length;
    if (found < 0) {
      // 跨段落选择时中间可能夹着段落分隔，退化为用前 20 字定位。
      final probe = target.length > 20 ? target.substring(0, 20) : target;
      found = flatText.indexOf(probe);
      if (found < 0) {
        _toast('定位失败，请重新选择');
        return;
      }
      length = probe.length;
    }
    final charStart = map[found];
    final lastIndex = (found + length - 1).clamp(0, map.length - 1);
    final charEnd = map[lastIndex] + 1;

    await _markings.add(
      bookId: widget.bookId,
      chapterId: _chapter.id,
      chapterIndex: _index,
      charStart: charStart,
      charEnd: charEnd,
      text: chapterText.substring(charStart, charEnd),
      chapterTitle: _chapter.title,
    );
    if (!mounted) return;
    _toast('已划线');
  }

  static String _stripSpaces(String text) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (_isSpace(text[i])) continue;
      buffer.write(text[i]);
    }
    return buffer.toString();
  }

  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == '\u3000';

  Future<void> _openBookmarks() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => _BookmarkSheet(
        store: _bookmarks,
        markings: _markings,
        bookId: widget.bookId,
        onJump: _jumpTo,
      ),
    );
  }

  /// 书签/划线跳转：换章 + 定位到字符位置。
  Future<void> _jumpTo(int chapterIndex, int charOffset) async {
    Navigator.of(context).maybePop();
    final target = chapterIndex.clamp(0, _maxIndex);
    if (target != _index) {
      await _go(target - _index, landing: _ChapterLanding.keep);
      if (!mounted) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    if (_paged) {
      final pagination = _pagination;
      if (pagination == null) return;
      final page = pagination.pageForChar(charOffset);
      _currentPage = page;
      _pager.jumpTo(page);
    } else {
      _continuous.jumpToTop();
    }
  }

  Future<void> _openReplaceRules() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReplaceRulesScreen(bookId: widget.bookId),
      ),
    );
  }

  /// 双模式「翻一页」：翻页模式走 PageView，滚动模式翻一屏，到边自动换章。
  Future<void> _stepPage(int delta) async {
    if (_paged) {
      if (_turnPage(delta)) return;
      if (delta > 0) {
        await _go(1, landing: _ChapterLanding.first);
      } else {
        await _go(-1, landing: _ChapterLanding.last);
      }
      return;
    }
    if (await _continuous.scrollByPage(delta)) return;
    if (delta > 0) {
      await _go(1, landing: _ChapterLanding.first);
    } else {
      await _go(-1, landing: _ChapterLanding.last);
    }
  }

  void _toast(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(milliseconds: 1200),
    ));
  }

  Future<void> _openClickZoneEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ReaderClickZoneEditor(store: _settingsStore),
    );
  }

  /// 自动翻页计时器：只在翻页模式且开关打开时跑。
  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (!_autoTurn || !_paged) return;
    _autoTimer = Timer.periodic(Duration(seconds: _autoInterval), (_) {
      if (!mounted) return;
      _turnPage(1);
    });
  }

  /// 键盘：空格/→ 下一页，← 上一页（翻页模式）；滚动模式下空格下翻一段。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // 音量键翻页：桌面端与外接键盘有效；安卓上系统同时会调音量。
    if (_settingsStore.value.volumeKeyPage &&
        (key == LogicalKeyboardKey.audioVolumeUp ||
            key == LogicalKeyboardKey.audioVolumeDown)) {
      // ignore: discarded_futures
      _stepPage(key == LogicalKeyboardKey.audioVolumeUp ? -1 : 1);
      return KeyEventResult.handled;
    }

    if (_paged) {
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.arrowRight) {
        _turnPage(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _turnPage(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space) {
      if (!_scroll.hasClients) return KeyEventResult.ignored;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((_scroll.offset + 160).clamp(0.0, max));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 正文段落（已做简繁转换）。转换结果按「章 + 模式」缓存。
  List<String> get _displayParagraphs {
    final paragraphs = _paragraphs;
    if (paragraphs == null) return const <String>[];
    final mode = _settings.convert;
    if (mode == ChineseConvert.off) return paragraphs;
    final key = '${_chapter.id}|${mode.name}';
    if (_convertedKey == key && _converted != null) return _converted!;
    _converted = [
      for (final paragraph in paragraphs)
        ChineseConverter.convert(paragraph, mode),
    ];
    _convertedKey = key;
    return _converted!;
  }

  /// 页眉/页脚高度（跟随字号，保证小屏不吃掉正文）。
  double get _tipHeight =>
      ((_fontSize - 6).clamp(9.0, 14.0) * 1.2 + 8).clamp(18.0, 30.0);

  bool get _showHeaderTip {
    final mode = _settings.activeThemeConfig.headerMode;
    if (mode == ReaderTipMode.never) return false;
    if (mode == ReaderTipMode.always) return true;
    return _chrome;
  }

  bool get _showFooterTip {
    final mode = _settings.activeThemeConfig.footerMode;
    if (mode == ReaderTipMode.never) return false;
    if (mode == ReaderTipMode.always) return true;
    return _chrome;
  }

  /// 用实测约束做分页。相同键直接命中缓存，参数不变不重算。
  ReaderPagination _paginationFor(BuildContext context, Size size) {
    final paragraphs = _displayParagraphs;
    if (!_paged || paragraphs.isEmpty) return ReaderPagination.empty;
    final type = _type;
    final headerHeight = _showHeaderTip ? _tipHeight : 0.0;
    final footerHeight = _showFooterTip ? _tipHeight : 0.0;
    final geometry = ReaderPageGeometry(
      contentWidth: size.width - type.paddingLeft - type.paddingRight,
      contentHeight: size.height -
          type.paddingTop -
          type.paddingBottom -
          headerHeight -
          footerHeight,
      textScaler: MediaQuery.textScalerOf(context),
    );
    final key = [
      _chapter.id,
      _index,
      type.hashCode,
      geometry.contentWidth.toStringAsFixed(1),
      geometry.contentHeight.toStringAsFixed(1),
      geometry.textScaler.toString(),
      _settings.convert.name,
      // 正文签名：同章被替换规则或源站改过内容时必须重排。
      paragraphsSignature(paragraphs),
    ].join('|');
    final cached = _pagination;
    if (_paginationKey == key && cached != null) return cached;
    final result = paginateReader(
      paragraphs: paragraphs,
      typography: type,
      geometry: geometry,
      chapterTitle: type.includeChapterTitle ? _chapter.title : null,
    );
    _pagination = result;
    _paginationKey = key;
    if (_currentPage >= result.pageCount) {
      _currentPage = result.pageCount == 0 ? 0 : result.pageCount - 1;
    }
    return result;
  }

  ReaderPageRenderSpec _renderSpec(
    ReaderPagination pagination,
    int pageIndex, {
    bool leftHalf = false,
    bool rightHalf = false,
  }) {
    final config = _settings.activeThemeConfig;
    // 双页时把朝向中缝的一侧内边距减半，否则两页各自 22px 会拼出 44px 空隙。
    // 缩窄是安全的：分页按原宽度算，行只会更短，不会溢出。
    final type = leftHalf
        ? _type.copyWith(
            paddingRight: (_type.paddingRight / 2).clamp(0.0, 12.0))
        : rightHalf
            ? _type.copyWith(
                paddingLeft: (_type.paddingLeft / 2).clamp(0.0, 12.0))
            : _type;
    final tipContext = ReaderTipContext(
      bookName: widget.bookTitle,
      chapterTitle: _chapter.title,
      chapterIndex: _index,
      chapterSize: widget.chapters.length,
      pageIndex: pageIndex,
      pageSize: pagination.pageCount,
      progress: _offsetRatio,
      batteryPercent: BatteryLevelReader.read(),
    );
    return ReaderPageRenderSpec(
      typography: type,
      theme: config,
      night: _settings.nightMode,
      chapterTitle: _chapter.title,
      bookName: widget.bookTitle,
      chapterIndex: _index,
      chapterSize: widget.chapters.length,
      headerHeight: _showHeaderTip ? _tipHeight : 0,
      footerHeight: _showFooterTip ? _tipHeight : 0,
      header: buildTipLayout(
        left: config.headerLeft,
        middle: config.headerMiddle,
        right: config.headerRight,
        ctx: tipContext,
        customLeft: config.headerCustomLeft,
        customMiddle: config.headerCustomMiddle,
        customRight: config.headerCustomRight,
      ),
      footer: buildTipLayout(
        left: config.footerLeft,
        middle: config.footerMiddle,
        right: config.footerRight,
        ctx: tipContext,
        customLeft: config.footerCustomLeft,
        customMiddle: config.footerCustomMiddle,
        customRight: config.footerCustomRight,
      ),
      showHeader: _showHeaderTip,
      showFooter: _showFooterTip,
      progress: _offsetRatio,
      batteryPercent: tipContext.batteryPercent,
      markings: _markings.inChapter(widget.bookId, _chapter.id),
      onMarkRequested: _markSelection,
    );
  }

  /// HTML → 段落（章节标题去重 + 替换规则）。所有入口共用，保证口径一致。
  List<String> _deriveParagraphs(BookChapter chapter, String raw) {
    final paragraphs = htmlToParagraphs(raw);
    // 正文里常带一行章节标题，顶部已经显示了就不再重复。
    if (paragraphs.isNotEmpty && paragraphs.first == chapter.title) {
      paragraphs.removeAt(0);
    }
    return applyReplaceRules(paragraphs, _replaceRules.forBook(widget.bookId));
  }

  Future<void> _load(int index, {bool restore = false}) async {
    if (widget.chapters.isEmpty) return;
    final chapter = widget.chapters[index];

    // 已有原文：直接重新派生（替换规则变更后的快路径）。
    final raw = _rawCache[chapter.id];
    if (raw != null) {
      final paragraphs = _deriveParagraphs(chapter, raw);
      _cache[chapter.id] = paragraphs;
      setState(() {
        _index = index;
        _error = null;
        _paragraphs = paragraphs;
        _loading = false;
        _ready = true;
      });
      _paginationKey = '';
      _convertedKey = '';
      _afterLoad(restore: restore);
      _syncAutoTimer();
      _maybeToastReplace();
      return;
    }

    final cached = _cache[chapter.id];
    setState(() {
      _index = index;
      _error = null;
      _paragraphs = cached;
      _loading = cached == null;
      _ready = cached != null;
    });
    if (cached != null) {
      _afterLoad(restore: restore);
      return;
    }
    try {
      final text = await AppScope.read(context).api.chapterText(chapter.id);
      _rawCache[chapter.id] = text;
      final paragraphs = _deriveParagraphs(chapter, text);
      _cache[chapter.id] = paragraphs;
      // 落盘带正文签名：源站改过正文时这张缓存会被判为过期。
      await _cacheStore.put(
        chapter.id,
        text,
        signature: contentSignature(text),
      );
      if (!mounted || _index != index) return;
      setState(() {
        _paragraphs = paragraphs;
        _loading = false;
        _ready = true;
      });
      _paginationKey = '';
      _convertedKey = '';
      _afterLoad(restore: restore);
      _syncAutoTimer();
      _maybeToastReplace();
      _prefetch(index + 1);
    } catch (e) {
      if (!mounted || _index != index) return;
      // 网络不可用但有缓存：退化成本地阅读，不弹错误。
      final offline = _cacheStore.text(chapter.id);
      if (offline != null && offline.isNotEmpty) {
        _rawCache[chapter.id] = offline;
        final paragraphs = _deriveParagraphs(chapter, offline);
        _cache[chapter.id] = paragraphs;
        setState(() {
          _paragraphs = paragraphs;
          _loading = false;
          _ready = true;
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
          _rawCache[chapter.id] = raw;
          _cache[chapter.id] = _deriveParagraphs(chapter, raw);
        })
        .catchError((Object _) {});
  }

  void _afterLoad({required bool restore}) {
    final landing = _landing;
    _landing = _ChapterLanding.keep;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_paged) {
        // 分页结果在 build 里按实测几何生成；这里只记下目标页，
        // `ReaderPager.didUpdateWidget` 会在分页就绪后同步索引。
        final count = _pagination?.pageCount ?? 0;
        var target = 0;
        if (landing == _ChapterLanding.last) {
          target = count > 0 ? count - 1 : 0;
        } else if (restore && !_restored) {
          _restored = true;
          final pagination = _pagination;
          if (widget.restoreCharOffset >= 0 && pagination != null) {
            // 字符偏移比比例精确：改过字号也能落回同一句。
            target = pagination.pageForChar(widget.restoreCharOffset);
          } else {
            target = count > 0
                ? (widget.restoreOffset * count).round() - 1
                : 0;
          }
        }
        if (count > 0) target = target.clamp(0, count - 1);
        _currentPage = target < 0 ? 0 : target;
        _pager.jumpTo(_spreadIndexOf(_currentPage));
        return;
      }
      if (landing == _ChapterLanding.last) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        } else {
          _continuous.jumpToBottom();
        }
        return;
      }
      if (landing == _ChapterLanding.first) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(0);
        } else {
          _continuous.jumpToTop();
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
    if (!_paged) return _continuousRatio;
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return 0;
    return ((_currentPage + 1) / pagination.pageCount).clamp(0.0, 1.0);
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _persist);
  }

  /// 当前阅读位置的章内字符偏移；拿不到返回 -1。
  int get _currentCharOffset {
    if (_paged) {
      final pagination = _pagination;
      if (pagination == null || pagination.isEmpty) return -1;
      final index = _currentPage.clamp(0, pagination.pageCount - 1);
      return pagination.pages[index].charStart;
    }
    final paragraphs = _displayParagraphs;
    if (paragraphs.isEmpty) return -1;
    final target = _paragraphIndex.clamp(0, paragraphs.length - 1);
    var offset = 0;
    for (var i = 0; i < target; i++) {
      offset += paragraphs[i].length + 1;
    }
    return offset;
  }

  /// 从 [offset] 起取 40 字做书签摘录。
  String _excerptAt(int offset) {
    final text = _displayParagraphs.join('\n');
    if (text.isEmpty || offset < 0 || offset >= text.length) return '';
    final end = (offset + 40).clamp(0, text.length);
    return text
        .substring(offset, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _persist() async {
    // 正文没就绪时写盘会把「第 0 页」当成真实进度。
    if (!_ready || widget.chapters.isEmpty) return;
    final chapter = widget.chapters[_index];
    _persistSeq++;
    await _store.record(
      bookId: widget.bookId,
      title: widget.bookTitle,
      coverUrl: widget.coverUrl,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterIndex: _index,
      chapters: widget.chapters.length,
      offset: _offsetRatio,
      charOffset: _currentCharOffset,
      revision: _persistSeq,
    );
  }

  Future<void> _go(int delta, {_ChapterLanding landing = _ChapterLanding.keep}) async {
    final next = (_index + delta).clamp(0, _maxIndex);
    if (next == _index) {
      _toast(delta > 0 ? '已是最后一章' : '已是第一章');
      return;
    }
    await _persist();
    if (!mounted) return;
    _landing = landing;
    await _load(next);
  }

  /// 听书：从**当前这一章**开始听（番茄的听书入口就是这样）。
  void _openAudio() {
    if (widget.chapters.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookAudioScreen(
        bookId: widget.bookId,
        bookTitle: widget.bookTitle,
        coverUrl: widget.coverUrl,
        chapters: widget.chapters,
        startIndex: _index,
        startParagraph: _paragraphIndex,
        startRatio: _offsetRatio,
      ),
    ));
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

  Future<void> _showSettings() {
    final sample = _paragraphs?.isNotEmpty == true ? _paragraphs!.first : '';
    final preview = sample.isEmpty
        ? '春江潮水连海平，海上明月共潮生。'
        : (sample.length > 80 ? sample.substring(0, 80) : sample);
    return showReaderSettingsSheet(
      context,
      store: _settingsStore,
      previewText: preview,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    return Scaffold(
      backgroundColor: theme.background,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 只注册 tap：PageView 的横滑与 ListView 的纵滑仍在手势竞技场里优先，
          // 不会被这一层抢走。
          onTapUp: (details) {
            final size = context.size ?? MediaQuery.sizeOf(context);
            _onTapUp(details, size);
          },
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
      ),
    );
  }

  /// 底栏页码：双页显示区间（`3-4 / 20 页`）。
  String get _pageLabel {
    final total = _pagination?.pageCount ?? 0;
    if (!_paged || total <= 0) {
      return '${_index + 1} / ${widget.chapters.length}';
    }
    if (!_spreadEnabled) return '${_currentPage + 1} / $total 页';
    final left = _currentPage + 1;
    final right = (left + 1).clamp(left, total);
    return right == left ? '$left / $total 页' : '$left-$right / $total 页';
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
                tooltip: '书签与划线',
                icon: Icon(Icons.bookmarks_outlined, color: theme.foreground),
                onPressed: _openBookmarks,
              ),
              IconButton(
                tooltip: '听书',
                icon: Icon(Icons.headset, color: theme.foreground),
                onPressed: _openAudio,
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
              IconButton(
                tooltip: '点击区域',
                icon: Icon(Icons.touch_app_outlined, color: theme.foreground),
                onPressed: _openClickZoneEditor,
              ),
              TextButton(
                onPressed: _index > 0 ? () => _go(-1) : null,
                child: const Text('上一章'),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _pageLabel,
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

  Widget _buildPaged(_ReaderTheme theme) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pagination = _paginationFor(context, constraints.biggest);
          if (pagination.isEmpty) {
            return Center(
              child: Text(
                '本章暂无正文',
                style: TextStyle(
                  color: theme.foreground.withValues(alpha: 0.6),
                ),
              ),
            );
          }
          final spread = _spreadEnabled;
          final spreadCount = spread
              ? (pagination.pageCount + 1) ~/ 2
              : pagination.pageCount;
          final index = spread
              ? (_currentPage ~/ 2).clamp(0, spreadCount - 1)
              : _currentPage.clamp(0, spreadCount - 1);
          return ReaderPager(
            controller: _pager,
            pageCount: spreadCount,
            index: index,
            animation: _settings.anim,
            duration: Duration(milliseconds: _settings.animDurationMs),
            swipeEnabled: _settings.swipeEnabled,
            onIndexChanged: (i) {
              if (!mounted) return;
              _feedbackOnTurn();
              final single = spread ? i * 2 : i;
              if (single == _currentPage) return;
              setState(() => _currentPage = single);
              // ignore: discarded_futures
              _persist();
            },
            onOverscrollNext: () {
              // ignore: discarded_futures
              _go(1, landing: _ChapterLanding.first);
            },
            onOverscrollPrev: () {
              // ignore: discarded_futures
              _go(-1, landing: _ChapterLanding.last);
            },
            builder: (context, i) {
              if (!spread) {
                return RepaintBoundary(
                  child: ReaderPageContent(
                    page: pagination.pages[i],
                    pageIndex: i,
                    pageSize: pagination.pageCount,
                    spec: _renderSpec(pagination, i),
                  ),
                );
              }
              // 双页：左右各放一个已算好的单页，最后一屏右半留白。
              final left = i * 2;
              final right = left + 1;
              return RepaintBoundary(
                child: Row(
                  children: [
                    Expanded(
                      child: ReaderPageContent(
                        page: pagination.pages[left],
                        pageIndex: left,
                        pageSize: pagination.pageCount,
                        spec: _renderSpec(pagination, left, leftHalf: true),
                      ),
                    ),
                    Expanded(
                      child: right < pagination.pageCount
                          ? ReaderPageContent(
                              page: pagination.pages[right],
                              pageIndex: right,
                              pageSize: pagination.pageCount,
                              spec: _renderSpec(pagination, right,
                                  rightHalf: true),
                            )
                          : ColoredBox(color: _theme.background),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 取某章段落（连续阅读用；已加载的走缓存）。
  Future<List<String>> _paragraphsOf(int index) async {
    final chapter = widget.chapters[index];
    final cached = _cache[chapter.id];
    if (cached != null) return cached;
    final raw = _rawCache[chapter.id] ??
        await AppScope.read(context).api.chapterText(chapter.id);
    _rawCache[chapter.id] = raw;
    final ps = _deriveParagraphs(chapter, raw);
    _cache[chapter.id] = ps;
    return ps;
  }

  /// 连续阅读的位置回调：记录当前章/段与章内比例。
  void _onContinuousPosition(
      int chapterIndex, int paragraphIndex, double ratio) {
    _continuousRatio = ratio.clamp(0.0, 1.0);
    if (paragraphIndex != _paragraphIndex) _paragraphIndex = paragraphIndex;
    if (chapterIndex != _index) {
      setState(() => _index = chapterIndex);
    }
    // ignore: discarded_futures
    _persist();
  }

  Widget _buildBody(_ReaderTheme theme) {
    if (_paged && !_loading && _error == null && (_paragraphs?.isNotEmpty ?? false)) {
      return _buildPaged(theme);
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
    if (!_paged) {
      return SafeArea(
        bottom: false,
        child: ContinuousChapters(
          controller: _continuous,
          typography: _type,
          chapters: widget.chapters.map((c) => c.id).toList(),
          initialChapter: _index,
          loadChapter: (i, _) => _paragraphsOf(i),
          onPosition: _onContinuousPosition,
          chapterTitle: (context, chapterIndex, _) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.chapters[chapterIndex].title,
              style: TextStyle(
                color: theme.foreground,
                fontSize: _fontSize + 4,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
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
