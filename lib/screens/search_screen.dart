import 'dart:async';

import 'package:flutter/material.dart';

import '../core/search_dimensions.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'post_detail_screen.dart';

/// 搜索页：热搜首屏 → 输入时联想（300ms 防抖）→ 提交后结果流。
/// 结果流顶部提供内容筛选（综合/真人剧/漫剧/AI 剧），切筛选重新查询。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});

  /// 传入时自动以此词发起搜索（详情页标签、AI 入口用）。
  final String initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// 内容筛选：value 是 openhongguo 搜索 filters 的取值。
const _searchFilters = <String, String>{
  '': '综合',
  'content_type_short_play': '真人剧',
  'content_type_dynamic_comic': '漫剧',
  'content_type_ai_dynamic_comic': 'AI 剧',
};

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
  String _filter = '';

  /// 内容（作品）/ 讨论（帖子）两个维度。
  SearchDimension _dimension = SearchDimension.content;

  /// 请求序号：维度/筛选连点时，只有最后一次请求的结果能落地。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadHot();
    if (widget.initialQuery.trim().isNotEmpty) {
      _controller.text = widget.initialQuery;
      // 首帧后自动提交，让输入框的初始值走完整搜索流程。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit(widget.initialQuery);
      });
    }
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
    final seq = ++_seq;
    // 异步间隙前取好引用，避免 BuildContext 跨 await。
    final scope = AppScope.read(context);
    // 记录进搜索历史（新词置顶）；失败不影响搜索本身。
    try {
      await scope.searches.record(q);
    } catch (_) {}
    setState(() {
      _submitted = q;
      _searching = true;
      _results.clear();
      _suggestions = const [];
      _error = null;
    });
    try {
      final page = await scope.api.search(q,
          tab: _dimension.tab,
          filters: _dimension.filtersFor(
              _filter.isEmpty ? const [] : [_filter]));
      if (!mounted || seq != _seq) return;
      setState(() {
        _results.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _searching = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_searching || !_hasMore || _submitted.isEmpty) return;
    final seq = _seq;
    _searching = true;
    try {
      final page = await AppScope.read(context).api.search(
        _submitted,
        cursor: _cursor,
        // 服务端要求游标与筛选一起传，翻页沿用当前筛选。
        tab: _dimension.tab,
        filters:
            _dimension.filtersFor(_filter.isEmpty ? const [] : [_filter]),
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        // 服务端的翻页结果自带与上一页的重叠（与 ohg 分页语义一致），
        // 按 ID 去重后追加。
        final seen = {for (final r in _results) r.id};
        for (final item in page.items) {
          if (!seen.contains(item.id)) {
            seen.add(item.id);
            _results.add(item);
          }
        }
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      // 只有发起这一代请求的才能解锁，否则旧请求会把新一代的锁清掉。
      if (seq == _seq) _searching = false;
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
        return LoadView(
          loading: false,
          error: null,
          onRetry: null,
          empty: true,
          emptyText: _dimension == SearchDimension.discussion
              ? '没有找到相关讨论'
              : '没有找到相关短剧',
          child: const SizedBox(),
        );
      }
      return Column(
        children: [
          _buildFilterBar(context),
          Expanded(
            child: _dimension == SearchDimension.discussion
                ? _buildDiscussionList(context)
                : SeriesGrid(
                    items: _results,
                    hasMore: _hasMore,
                    onLoadMore: _loadMore,
                    onTap: (item) => openDetail(context, item.id, item.title),
                  ),
          ),
        ],
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
      header: _historyHeader(context),
      // 话题属于社区：点话题直接看讨论，而不是作品搜索。
      onTopic: (q) {
        setState(() => _dimension = SearchDimension.discussion);
        _controller.text = q;
        _submit(q);
      },
      onSeries: (item) => openDetail(context, item.seriesId, item.title),
    );
  }

  /// 维度条 + 内容筛选行：内容维度可叠加筛选，讨论维度不显示筛选。
  Widget _buildFilterBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final dimension in SearchDimension.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(dimension.label),
                selected: _dimension == dimension,
                onSelected: (_) {
                  if (_dimension == dimension) return;
                  setState(() => _dimension = dimension);
                  // 维度变了，结果与游标都要重来。
                  if (_submitted.isNotEmpty) _submit(_submitted);
                },
              ),
            ),
          if (_dimension.allowsFilters) ...[
            const SizedBox(width: 8),
            for (final e in _searchFilters.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(e.value),
                  selected: _filter == e.key,
                  onSelected: (_) {
                    if (_filter == e.key) return;
                    setState(() => _filter = e.key);
                    _submit(_submitted);
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 讨论维度的结果列表：帖子没有封面（上游只有 post_id + title），用行式列表。
  Widget _buildDiscussionList(BuildContext context) {
    final theme = Theme.of(context);
    final itemCount = _results.length + (_hasMore ? 1 : 0);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: itemCount,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i >= _results.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        final item = _results[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 48,
              child: item.coverUrl.isEmpty
                  ? Icon(Icons.forum_outlined, color: theme.colorScheme.primary)
                  : CoverImage(url: item.coverUrl),
            ),
          ),
          title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: item.description.isEmpty
              ? null
              : Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                PostDetailScreen(postId: item.id, title: item.title),
          )),
        );
      },
    );
  }

  /// 搜索历史区：没有历史时不占位；单删 / 清空实时生效。
  List<Widget> _historyHeader(BuildContext context) {
    final store = AppScope.read(context).searches;
    if (store.queries.isEmpty) return const [];
    return [
      ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final queries = store.queries;
          if (queries.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: sectionTitle(context, '搜索历史')),
                  IconButton(
                    tooltip: '清空搜索历史',
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    onPressed: store.clear,
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in queries)
                    InputChip(
                      label: Text(q,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onPressed: () {
                        _controller.text = q;
                        _submit(q);
                      },
                      onDeleted: () => store.remove(q),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    ];
  }
}

class _HotView extends StatelessWidget {
  const _HotView({
    required this.hot,
    required this.onTopic,
    required this.onSeries,
    this.header = const [],
  });

  final HotSearch hot;

  /// 话题词 → 讨论维度搜索。
  final void Function(String) onTopic;
  final void Function(HotItem) onSeries;

  /// 插在热搜内容之前的区块（搜索历史）。
  final List<Widget> header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    if (hot.guesses.isNotEmpty) {
      children.add(sectionTitle(context, '猜你想搜'));
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
      children.add(sectionTitle(context, board.name));
      if (board.topics.isNotEmpty) {
        children.add(Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in board.topics)
              ActionChip(
                label: Text('#${t.title}'),
                onPressed: () => onTopic(t.query),
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
        for (final w in [...header, ...children]) ...[w, const SizedBox(height: 16)],
      ],
    );
  }
}

Widget sectionTitle(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold)),
    );

/// 搜索页入口（发现页 / 主壳 AppBar 调用）；[query] 传入时自动搜索。
void showSearchScreen(BuildContext context, {String? query}) {
  Navigator.of(context).push(
    MaterialPageRoute(
        builder: (_) => SearchScreen(initialQuery: query ?? '')),
  );
}
