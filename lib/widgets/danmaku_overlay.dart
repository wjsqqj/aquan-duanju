import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bili/api.dart';

/// 弹幕展示层（MVP：滚动弹幕，Canvas 自绘；发送/高级屏蔽留二期）。
///
/// 位置由播放器每帧喂入 [position]；滚动时长 8s，进入（progress 出现）后从
/// 右侧划到左侧，超过屏宽即移除。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.enabled = true,
  });

  final List<DanmakuItem> items;

  /// 当前播放位置（每帧更新）。
  final Duration position;
  final bool enabled;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 30fps 重绘（避免每帧 setState 的开销也够流畅）。
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (mounted && widget.enabled) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.items.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _DanmakuPainter(
          items: widget.items,
          position: widget.position,
          textStyle: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            shadows: [
              Shadow(blurRadius: 2, color: Colors.black54, offset: Offset(1, 1)),
            ],
          ),
        ),
        size: Size.infinite,
      ),
    );
  }
}

const int _scrollMs = 8000;

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.items,
    required this.position,
    required this.textStyle,
  });

  final List<DanmakuItem> items;
  final Duration position;
  final TextStyle textStyle;

  static final Map<String, TextPainter> _painterCache = {};

  @override
  void paint(Canvas canvas, Size size) {
    final posMs = position.inMilliseconds;
    const scrollMs = _scrollMs;
    // 只画 [pos - 8s, pos] 窗口内的弹幕（进入即开始滚动）。
    final active = <DanmakuItem>[];
    for (final item in items) {
      final delta = posMs - item.progressMs;
      if (delta >= 0 && delta <= scrollMs) active.add(item);
    }
    // 轨道分配：按 progress 顺序，每 5 条一条轨道防重叠。
    const trackHeight = 26.0;
    for (var i = 0; i < active.length; i++) {
      final item = active[i];
      final painter = _painterFor(item.text);
      final progress = (posMs - item.progressMs) / scrollMs;
      final x = size.width - progress * (size.width + painter.width) -
          painter.width * 0;
      if (x + painter.width < 0) continue;
      final y = (i % 8) * trackHeight + 8;
      painter.paint(canvas, Offset(x, y));
    }
  }

  TextPainter _painterFor(String text) {
    if (_painterCache.length > 600) _painterCache.clear();
    return _painterCache.putIfAbsent(text, () {
      final tp = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp;
    });
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) => true;
}
