import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 上新日历：newReleases(date)，服务端给出今天前后各一周的日期。
/// 已上线的作品可点进详情；预告作品显示上线时间与预约人数。
class ReleasesScreen extends StatefulWidget {
  const ReleasesScreen({super.key});

  @override
  State<ReleasesScreen> createState() => _ReleasesScreenState();
}

class _ReleasesScreenState extends State<ReleasesScreen> {
  List<String> _dates = const [];
  String _selectedDate = '';
  List<NewRelease> _items = const [];
  bool _hasMore = false;
  String _cursor = '';
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? date}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      final page = await api.newReleases(date: date ?? '');
      if (!mounted) return;
      setState(() {
        if (page.dates.isNotEmpty) _dates = page.dates;
        _selectedDate = page.date.isNotEmpty
            ? page.date
            : (date ?? _dates.firstOrNull ?? '');
        _items = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await AppScope.read(context)
          .api
          .newReleases(date: _selectedDate, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('上新')),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: () => _load(),
        empty: _items.isEmpty,
        emptyText: '这一天没有上新',
        child: Column(
          children: [
            if (_dates.isNotEmpty)
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    for (final d in _dates)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(_dateLabel(d)),
                          selected: d == _selectedDate,
                          onSelected: (_) => _load(date: d),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: _items.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (i >= _items.length) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _loadMore());
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 22,
                            height: 22,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    );
                  }
                  final item = _items[i];
                  return _ReleaseCard(item: item);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// YYYYMMDD → 「10月28日」。
  String _dateLabel(String raw) {
    final d = DateTime.tryParse(
        raw.length == 8 ? '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}' : raw);
    if (d == null) return raw;
    return '${d.month}月${d.day}日';
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.item});

  final NewRelease item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = [
      if (item.online && item.episodeCount > 0) '已上线 · 共${item.episodeCount}集',
      if (!item.online) item.note,
      if (item.heat.isNotEmpty) item.heat,
      if (item.categories.isNotEmpty) item.categories.take(2).join(' · '),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: item.online && item.seriesId.isNotEmpty
            ? () => openDetail(context, item.seriesId, item.title)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 84,
                  height: 116,
                  child: CoverImage(url: item.coverUrl),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(item.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      if (!item.online)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('预告',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onTertiaryContainer)),
                        ),
                    ]),
                    if (item.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(item.description,
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(sub,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
