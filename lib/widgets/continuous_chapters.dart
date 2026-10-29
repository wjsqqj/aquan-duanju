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

  /// 章标题的渲染（默认用章节序号 + 标题文本）。
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
  bool _loadingNext = false;
  Timer? _report;
  bool _didInitialJump = false;

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
    final id = widget.chapters[chapterIndex];
    final paragraphs = await widget.loadChapter(chapterIndex, id);
    if (!mounted) return;
    final start = _flat.length;
    _flat.add(_Flat(chapterIndex, true, ''));
    for (final p in paragraphs) {
      _flat.add(_Flat(chapterIndex, false, p));
    }
    _chapterStart[chapterIndex] = start;
    _loadedThrough = chapterIndex;
    setState(() {});
    if (!_didInitialJump) {
      _didInitialJump = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToChapter(widget.initialChapter));
    }
  }

  void _jumpToChapter(int chapterIndex) {
    if (!_scroll.hasClients) return;
    final key = _titleKeys[chapterIndex];
    final box = key?.currentContext?.findRenderObject();
    if (box is RenderBox) {
      final dy = box.localToGlobal(Offset.zero).dy;
      _scroll.jumpTo((_scroll.offset + dy - 8).clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  /// 快到底了就把下一章接上来（位置不会跳，因为是往下追加）。
  Future<void> _maybeLoadNext() async {
    if (_loadingNext || _loadedThrough < 0) return;
    if (_loadedThrough >= widget.chapters.length - 1) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent - _scroll.offset > 900) return;
    _loadingNext = true;
    try {
      await _append(_loadedThrough + 1);
    } finally {
      _loadingNext = false;
    }
  }  /// 报告当前位置：当前章、章内段落下标与章内比例。
  void _onScroll() {
    _maybeLoadNext();
    _report?.cancel();
    _report = Timer(const Duration(milliseconds: 600), _reportPosition);
  }

  void _reportPosition() {
    if (!mounted || _flat.isEmpty) return;
    var current = _loadedThrough;
    double chapterTop = 0;
    for (final entry in _titleKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= 8) {
        current = entry.key;
        chapterTop = dy;
      }
    }
    // 章内比例：用章标题的屏幕位置与章高粗估（章标题只占几像素，这里用
    // 下一个章标题的位置差更准）。
    final nextTop = _chapterTopOf(current + 1);
    final span = (nextTop - chapterTop).abs();
    final ratio = span > 1 ? ((chapterTop - 0) / span).clamp(0.0, 1.0) : 0.0;
    final paragraphIndex = (ratio * _paragraphCount(current)).floor();
    widget.onPosition(current, paragraphIndex.clamp(0, _paragraphCount(current) - 1), ratio);
  }

  double _chapterTopOf(int chapterIndex) {
    final box = _titleKeys[chapterIndex]?.currentContext?.findRenderObject();
    if (box is RenderBox) return box.localToGlobal(Offset.zero).dy;
    return 0;
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