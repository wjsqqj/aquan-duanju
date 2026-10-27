import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 搜索页：热搜首屏 → 输入时联想（300ms 防抖）→ 提交后结果流。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  HotSearch? _hot;
  List<Suggestion> _suggestions = const [];
  final _results = <SeriesSummary>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _searching = false;
  bool _loadingHot = true;
  Object? _error;
  String _submitted = '';

  @override
  void initState() {
    super.initState();
    _loadHot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHot() async {
    try {
      final hot = await AppScope.read(context).api.hotSearch();
      if (!mounted) return;
      setState(() {
        _hot = hot;
        _loadingHot = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loadingHot = false;
      });
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final list = await AppScope.read(context).api.suggest(text.trim());
        if (!mounted) return;
        setState(() => _suggestions = list.take(10).toList());
      } catch (_) {}
    });
  }

  Future<void> _submit(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _focus.unfocus();
    setState(() {
      _submitted = q;
      _searching = true;
      _results.clear();
      _suggestions = const [];
      _error = null;
    });
    try {
      final page = await AppScope.read(context).api.search(q);
      if (!mounted) return;
      setState(() {
        _results.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _searching = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_searching || !_hasMore || _submitted.isEmpty) return;
    _searching = true;
    try {
      final page = await AppScope.read(context)
          .api
          .search(_submitted, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _results.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      _searching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: '搜索短剧、演员',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_submitted.isNotEmpty) {
      if (_searching && _results.isEmpty) return const SkeletonGrid();
      if (_error != null) {
        return ErrorRetryView(error: _error!, onRetry: () => _submit(_submitted));
      }
      if (_results.isEmpty) {
        return const LoadView(
          loading: false,
          error: null,
          onRetry: null,
          empty: true,
          emptyText: '没有找到相关短剧',
          child: SizedBox(),
        );
      }
      return SeriesGrid(
        items: _results,
        hasMore: _hasMore,
        onLoadMore: _loadMore,
        onTap: (item) => openDetail(context, item.id, item.title),
      );
    }

    // 未提交：联想优先，否则热搜首屏。
    if (_suggestions.isNotEmpty) {
      return ListView.builder(
        itemCount: _suggestions.length,
        itemBuilder: (context, i) {
          final s = _suggestions[i];
          return ListTile(
            leading: const Icon(Icons.search, size: 20),
            title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              _controller.text = s.text;
              _submit(s.keyword.isNotEmpty ? s.keyword : s.text);
            },
          );
        },
      );
    }

    if (_loadingHot) {
      return const SkeletonGrid(columns: 1);
    }
    if (_hot == null) {
      return ErrorRetryView(
          error: _error ?? StateError('hot search'), onRetry: _loadHot);
    }
    return _HotView(
      hot: _hot!,
      onQuery: (q) {
        _controller.text = q;
        _submit(q);
      },
      onSeries: (item) => openDetail(context, item.seriesId, item.title),
    );
  }
}

class _HotView extends StatelessWidget {
  const _HotView({required this.hot, required this.onQuery, required this.onSeries});

  final HotSearch hot;
  final void Function(String) onQuery;
  final void Function(HotItem) onSeries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    if (hot.guesses.isNotEmpty) {
      children.add(_sectionTitle(context, '猜你想搜'));
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final g in hot.guesses.take(8))
            ActionChip(
              label: Text(g.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => onSeries(g),
            ),
        ],
      ));
    }
    for (final board in hot.boards) {
      children.add(_sectionTitle(context, board.name));
      if (board.topics.isNotEmpty) {
        children.add(Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in board.topics)
              ActionChip(
                label: Text('#${t.title}'),
                onPressed: () => onQuery(t.query),
              ),
          ],
        ));
      }
      if (board.items.isNotEmpty) {
        children.add(Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (final item in board.items)
                ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 28,
                    child: Text(
                      '${item.position}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: item.position <= 3
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: item.heat.isEmpty
                      ? null
                      : Text(item.heat, style: theme.textTheme.bodySmall),
                  trailing: item.tag.isEmpty
                      ? null
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(item.tag, style: theme.textTheme.bodySmall),
                        ),
                  onTap: () => onSeries(item),
                ),
            ],
          ),
        ));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        for (final w in children) ...[w, const SizedBox(height: 16)],
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );
}

/// 搜索页入口（发现页 / 主壳 AppBar 调用）。
void showSearchScreen(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const SearchScreen()),
  );
}
