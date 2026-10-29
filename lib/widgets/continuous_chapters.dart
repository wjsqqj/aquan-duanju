import 'dart:async';

import 'package:flutter/material.dart';

/// 连续阅读体：把章节按需拼成一条长列表，读到底自动接上下一章。
///
/// 段落是列表里的独立 item，所以「现在读到第几段」可以直接由 item 下标得出；
/// 章标题各带一个 GlobalKey，用它的屏幕位置判断当前章与章内比例。
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
      // 追加完如果已经在底部附近，继续接下一章（避免首章加载期间错过的触底）。
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
    final box = _titleKeys[chapterIndex]?.currentContext?.findRenderObject();
    if (box is RenderBox) {
      final dy = box.localToGlobal(Offset.zero).dy;
      _scroll.jumpTo((_scroll.offset + dy - 8)
          .clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  /// 快到底了就把下一章接上来（位置不会跳，因为是往下追加）。
  Future<void> _maybeLoadNext() async {
    if (_appending || _loadedThrough < 0) return;
    if (_loadedThrough >= widget.chapters.length - 1) return;
    if (!_nearBottom) return;
    await _append(_loadedThrough + 1);
  }  /// 报告当前位置：当前章、章内段落下标与章内比例。
  void _onScroll() {
    _maybeLoadNext();
    _report?.cancel();
    _report = Timer(const Duration(milliseconds: 600), _reportPosition);
  }

  /// 章标题的屏幕 y（相对视口顶）；没渲染时返回 null。
  double? _titleTop(int chapterIndex) {
    final box = _titleKeys[chapterIndex]?.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    return box.localToGlobal(Offset.zero).dy;
  }

  void _reportPosition() {
    if (!mounted || _flat.isEmpty) return;
    final keys = _titleKeys.keys.toList()..sort();
    if (keys.isEmpty) return;

    // 当前章 = 最后一个标题已经滚过视口顶（y <= 0）的章；都还没滚过就是第一章。
    var current = keys.first;
    var chapterTop = _titleTop(current) ?? 0;
    for (final k in keys) {
      final top = _titleTop(k);
      if (top == null) continue;
      if (top <= 0) {
        current = k;
        chapterTop = top;
      }
    }
    final nextTop = _titleTop(current + 1);
    // 章内比例 = 已滚过本章标题的距离 / 本章到下一章标题的整段距离。
    final span = (nextTop == null) ? 0.0 : (nextTop - chapterTop);
    final ratio = span > 1
        ? ((0 - chapterTop) / span).clamp(0.0, 1.0)
        : 0.0;
    final count = _paragraphCount(current);
    final paragraphIndex = count <= 0 ? 0 : (ratio * count).floor().clamp(0, count - 1);
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