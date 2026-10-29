import 'dart:async';

import 'package:flutter/material.dart';

/// 连续阅读体：把章节按需拼成一条长列表，读到底自动接上下一章。
///
/// 段落是列表里的独立 item，所以「现在读到第几段」可以直接由 item 下标得出。
///
/// **当前章的判定不能依赖 GlobalKey 的 context**：ListView 会回收屏幕外的 item，
/// 被回收后 context 变 null，于是「当前章」会退回第一个已加载的章（表现为读到
/// 第八章又跳回第四章）。这里改为在**构建时**把每章起点的绝对 offset 记下来，
/// 之后只用 offset 表判断。
class ContinuousChapters extends StatefulWidget {
  const ContinuousChapters({
    super.key,
    required this.chapters,
    required this.initialChapter,
    required this.loadChapter,
    required this.onPosition,
    this.chapterTitle,
  });

  /// 全部章节的 id（顺序即阅读顺序）。
  final List<String> chapters;

  /// 起始章下标。
  final int initialChapter;

  /// 取某章的段落文本。
  final Future<List<String>> Function(int index, String chapterId) loadChapter;

  /// 位置变化：(章下标, 段下标, 章内比例 0..1)。
  final void Function(int chapterIndex, int paragraphIndex, double ratio)
      onPosition;

  /// 章标题的渲染。
  final Widget Function(BuildContext context, int chapterIndex, String title)?
      chapterTitle;

  @override
  State<ContinuousChapters> createState() => _ContinuousChaptersState();
}

class _Flat {
  _Flat(this.chapter, this.isTitle, this.text);

  final int chapter;
  final bool isTitle;
  final String text;
}

class _ContinuousChaptersState extends State<ContinuousChapters> {
  final _scroll = ScrollController();
  final _flat = <_Flat>[];
  final _chapterStart = <int, int>{};
  final _titleKeys = <int, GlobalKey>{};

  /// 每章起点在滚动内容中的绝对 offset（构建时记录一次，之后长期有效）。
  final _chapterOffsets = <int, double>{};

  int _loadedThrough = -1;

  /// 同一时刻只允许一次追加：并发追加会让章节顺序交错（曾出现 5→7→6）。
  bool _appending = false;
  bool _didInitialJump = false;
  Timer? _report;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _append(widget.initialChapter);
  }

  @override
  void dispose() {
    _report?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _append(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= widget.chapters.length) return;
    if (_appending) return;
    _appending = true;
    try {
      final id = widget.chapters[chapterIndex];
      final paragraphs = await widget.loadChapter(chapterIndex, id);
      if (!mounted) return;
      _chapterStart[chapterIndex] = _flat.length;
      _flat.add(_Flat(chapterIndex, true, ''));
      for (final p in paragraphs) {
        _flat.add(_Flat(chapterIndex, false, p));
      }
      if (chapterIndex > _loadedThrough) _loadedThrough = chapterIndex;
      setState(() {});
      if (!_didInitialJump) {
        _didInitialJump = true;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _jumpToChapter(widget.initialChapter));
      }
      // 追加完若仍在底部附近，继续接下一章（首章加载期间错过的触底要补上）。
      if (_nearBottom) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _maybeLoadNext());
      }
    } finally {
      _appending = false;
    }
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return false;
    return _scroll.position.maxScrollExtent - _scroll.offset < 900;
  }

  void _jumpToChapter(int chapterIndex) {
    if (!_scroll.hasClients) return;
    var target = _chapterOffsets[chapterIndex];
    if (target == null) {
      // 起点还没记上（首帧）：退回用标题 widget 的位置。
      final box = _titleKeys[chapterIndex]?.currentContext?.findRenderObject();
      if (box is! RenderBox) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _jumpToChapter(chapterIndex));
        return;
      }
      target = _scroll.offset + box.localToGlobal(Offset.zero).dy;
    }
    _scroll.jumpTo(
        (target - 8).clamp(0.0, _scroll.position.maxScrollExtent));
  }

  /// 快到底了就把下一章接上来（位置不会跳，因为是往下追加）。
  Future<void> _maybeLoadNext() async {
    if (_appending || _loadedThrough < 0) return;
    if (_loadedThrough >= widget.chapters.length - 1) return;
    if (!_nearBottom) return;
    await _append(_loadedThrough + 1);
  }  /// 记录某章起点的绝对 offset（构建时 context 一定可用，之后不再依赖它）。
  void _rememberChapterStart(int chapterIndex, GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox) return;
      final offset = _scroll.offset + box.localToGlobal(Offset.zero).dy;
      final old = _chapterOffsets[chapterIndex];
      // 同一章可能被构建多次，取更靠前（更小）的那个作为起点。
      if (old == null || offset < old) _chapterOffsets[chapterIndex] = offset;
    });
  }

  void _onScroll() {
    _maybeLoadNext();
    _report?.cancel();
    _report = Timer(const Duration(milliseconds: 600), _reportPosition);
  }

  void _reportPosition() {
    if (!mounted || _flat.isEmpty || !_scroll.hasClients) return;
    final keys = _chapterOffsets.keys.toList()..sort();
    if (keys.isEmpty) return;
    final offset = _scroll.offset;

    // 当前章 = 起点已经滚过去的最后一章。
    var current = keys.first;
    for (final k in keys) {
      final start = _chapterOffsets[k] ?? double.infinity;
      if (start <= offset) current = k;
    }
    final start = _chapterOffsets[current] ?? offset;
    final scrolled = offset - start;
    final count = _paragraphCount(current);
    final nextStart = _chapterOffsets[current + 1];
    final double ratio;
    if (nextStart != null && nextStart > start) {
      // 下一章已加载：用真实章高算比例（最准）。
      ratio = ((scrolled / (nextStart - start)).clamp(0.0, 1.0));
    } else {
      // 下一章还没加载：用本章估计高度兜底（段落数 × 平均段高 42），
      // 否则比例恒为 0，听书会总从章开头开始。
      final est = count <= 0 ? 1.0 : count * 42.0;
      ratio = (scrolled / est).clamp(0.0, 1.0);
    }
    final paragraphIndex =
        count <= 0 ? 0 : (ratio * count).floor().clamp(0, count - 1);
    widget.onPosition(current, paragraphIndex, ratio);
  }

  int _paragraphCount(int chapterIndex) {
    var count = 0;
    for (final item in _flat) {
      if (item.chapter == chapterIndex && !item.isTitle) count++;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 140),
      itemCount: _flat.length,
      itemBuilder: (context, i) {
        final item = _flat[i];
        if (item.isTitle) {
          final key = _titleKeys.putIfAbsent(item.chapter, GlobalKey.new);
          _rememberChapterStart(item.chapter, key);
          return Padding(
            key: key,
            padding: const EdgeInsets.only(top: 22, bottom: 12),
            child: widget.chapterTitle?.call(context, item.chapter, '') ??
                Text('第 ${item.chapter + 1} 章',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(item.text, style: _bodyStyle(theme)),
        );
      },
    );
  }

  TextStyle _bodyStyle(ThemeData theme) => TextStyle(
        fontSize: 19,
        height: 1.8,
        color: theme.textTheme.bodyLarge?.color,
      );
}