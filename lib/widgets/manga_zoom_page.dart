import 'package:flutter/material.dart';

import '../models/manga.dart';
import 'manga_image.dart';

/// 全屏缩放查看：左右翻页、双指捏合、双击放大/还原。
///
/// 连续阅读页不做缩放，避免手势打架；需要看细节时双击进入这里。
class MangaZoomPage extends StatefulWidget {
  const MangaZoomPage({
    super.key,
    required this.pages,
    required this.keyHex,
    required this.initialIndex,
  });

  final List<MangaPage> pages;
  final String keyHex;
  final int initialIndex;

  @override
  State<MangaZoomPage> createState() => _MangaZoomPageState();
}

class _MangaZoomPageState extends State<MangaZoomPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  final _transforms = <int, TransformationController>{};
  late int _index = widget.initialIndex;
  bool _chrome = true;

  TransformationController _transformOf(int index) => _transforms.putIfAbsent(
        index,
        () => TransformationController(),
      );

  @override
  void dispose() {
    _controller.dispose();
    for (final t in _transforms.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _toggleZoom(int index) {
    final transform = _transformOf(index);
    final current = transform.value.getMaxScaleOnAxis();
    // 双击在 1x 与 2.5x 之间切换；已是放大态则还原。
    final factor = current > 1.05 ? 1 / current : 2.5;
    final next = transform.value.clone();
    next.scaleByDouble(factor, factor, factor, 1);
    transform.value = next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.pages.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              final page = widget.pages[i];
              return GestureDetector(
                onDoubleTap: () => _toggleZoom(i),
                onTap: () => setState(() => _chrome = !_chrome),
                child: InteractiveViewer(
                  transformationController: _transformOf(i),
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: MangaPageImage(
                      url: page.url,
                      keyHex: widget.keyHex,
                      aspectRatio: page.aspectRatio,
                    ),
                  ),
                ),
              );
            },
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 160),
            left: 0,
            right: 0,
            top: _chrome ? 0 : -110,
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      Text(
                        '${_index + 1} / ${widget.pages.length}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const Spacer(),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_chrome)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: Text(
                  '双击放大 · 双指缩放 · 左右翻页',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
