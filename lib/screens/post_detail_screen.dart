import 'package:flutter/material.dart';

import '../models/post.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 帖子详情：正文块按顺序渲染（文本 / 图片 / 话题 / 剧集卡片）。
class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.title = '',
  });

  final String postId;

  /// 列表页带过来的标题，加载期间占位。
  final String title;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  CommunityPost? _post;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final post = await AppScope.read(context).api.postDetail(widget.postId);
      if (!mounted) return;
      setState(() {
        _post = post;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('帖子')),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final post = _post;
    if (post == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          post.title.isNotEmpty ? post.title : widget.title,
          style:
              theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (post.author.isNotEmpty)
              Flexible(
                child: Text(post.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ),
            if (post.createdAt > 0) ...[
              const SizedBox(width: 8),
              Text(_formatDate(post.createdAt),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
            const Spacer(),
            Icon(Icons.thumb_up_off_alt, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 3),
            Text('${post.diggCount}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(width: 10),
            Icon(Icons.mode_comment_outlined,
                size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 3),
            Text('${post.replyCount}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
        if (post.tags.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [for (final tag in post.tags) Chip(label: Text(tag))],
          ),
        ],
        const Divider(height: 24),
        for (final block in post.blocks) _buildBlock(context, block),
      ],
    );
  }

  Widget _buildBlock(BuildContext context, PostBlock block) {
    final theme = Theme.of(context);
    if (block.isImage) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: double.infinity,
            child: CoverImage(url: block.url, fit: BoxFit.fitWidth),
          ),
        ),
      );
    }
    if (block.isSeries) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: SizedBox(
            width: 52,
            height: 70,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CoverImage(url: block.url),
            ),
          ),
          title: Text(
            block.title.isEmpty ? '相关剧集' : block.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.play_arrow),
          onTap: block.seriesId.isEmpty
              ? null
              : () => openDetail(context, block.seriesId,
                  block.title.isEmpty ? '相关剧集' : block.title),
        ),
      );
    }
    if (block.isTopic) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Chip(
            label: Text('#${block.text}'),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        block.text,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.7, fontSize: 16),
      ),
    );
  }

  String _formatDate(int unixSeconds) {
    final time = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}
