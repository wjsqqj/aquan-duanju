import 'package:flutter/material.dart';

import '../../core/reader/reader_settings.dart';

/// 一页在翻动过程中的呈现。
class ReaderTurnFrame {
  const ReaderTurnFrame({
    this.dx = 0,
    this.dy = 0,
    this.opacity = 1,
    this.scale = 1,
    this.dim = 0,
    this.curl = 0,
  });

  /// 横向偏移（占页宽比例）。
  final double dx;

  /// 纵向偏移（占页高比例）。
  final double dy;
  final double opacity;
  final double scale;

  /// 0..1，越大越暗。
  final double dim;

  /// 0..1，仿真翻页的卷曲进度。
  final double curl;

  double get translateX => dx;
  double get translateY => dy;
}

/// 纯函数：把翻页进度映射成某一页的呈现。
///
/// [progress]：0 表示稳定在当前页；>0 表示正在翻到上一页；<0 表示正在翻到下一页。
ReaderTurnFrame readerTurnFrame({
  required double progress,
  required bool isCurrent,
  required bool isPrev,
  required bool isNext,
  required ReaderPageAnim anim,
}) {
  final p = progress.clamp(-1.0, 1.0);
  final abs = p.abs();

  switch (anim) {
    case ReaderPageAnim.none:
      // 无过渡：旧页一直显示，直到进度走完直接换页。
      return ReaderTurnFrame(
        opacity: isCurrent ? 1 : (abs >= 0.999 ? 1 : 0),
      );

    case ReaderPageAnim.slide:
      final dx = isCurrent
          ? p
          : isPrev
              ? p - 1
              : p + 1;
      return ReaderTurnFrame(dx: dx, dim: isCurrent ? 0 : 0);

    case ReaderPageAnim.cover:
      if (p < 0) {
        // 下一页从右侧压上来，当前页不动、略缩略暗。
        if (isNext) return ReaderTurnFrame(dx: p + 1);
        return ReaderTurnFrame(
          dx: 0,
          scale: 1 - 0.05 * abs,
          dim: 0.22 * abs,
        );
      }
      if (p > 0) {
        // 上一页从左侧覆盖回来。
        if (isPrev) return ReaderTurnFrame(dx: p - 1);
        return ReaderTurnFrame(
          dx: 0,
          scale: 1 - 0.05 * abs,
          dim: 0.22 * abs,
        );
      }
      return const ReaderTurnFrame();

    case ReaderPageAnim.fade:
      if (isCurrent) return ReaderTurnFrame(opacity: 1 - abs);
      return ReaderTurnFrame(opacity: abs, scale: 1 - 0.02 * (1 - abs));

    case ReaderPageAnim.upDown:
      if (isCurrent) return ReaderTurnFrame(dy: p);
      if (isNext) return ReaderTurnFrame(dy: p + 1);
      return ReaderTurnFrame(dy: p - 1);

    case ReaderPageAnim.curl:
      if (p <= 0) {
        // 下一页从右边缘揭开，当前页右侧被卷起。
        if (isNext) return ReaderTurnFrame(dx: p + 1);
        return ReaderTurnFrame(curl: abs, dim: 0.16 * abs);
      }
      // 反向翻页退化为覆盖，避免自绘两个方向的卷曲。
      if (isPrev) return ReaderTurnFrame(dx: p - 1);
      return ReaderTurnFrame(dim: 0.18 * abs);
  }
}

/// 翻页容器控制器（点击翻页 / 换章定位用）。
class ReaderPagerController {
  _ReaderPagerState? _state;

  void _attach(_ReaderPagerState state) => _state = state;

  void _detach(_ReaderPagerState state) {
    if (identical(_state, state)) _state = null;
  }

  int get index => _state?._index ?? 0;

  bool get isAnimating => _state?._anim.isAnimating ?? false;

  /// 带动画翻到指定页；越界返回 false。
  Future<bool> goTo(int target) async {
    final state = _state;
    if (state == null) return false;
    return state.goTo(target);
  }

  /// 无动画跳转（换章后用）。
  void jumpTo(int target) {
    _state?.jumpTo(target);
  }
}

/// 自定义翻页容器。
///
/// 不用 `PageView` 的物理滚动，因为 6 种动画里只有「滑动」与原生滚动等价，
/// 覆盖 / 淡入 / 上下 / 仿真都需要把页面固定在特定位置再单独变换。
/// 手势（拖拽 + 甩动）在这里自己实现，语义与 PageView 一致。
class ReaderPager extends StatefulWidget {
  const ReaderPager({
    super.key,
    required this.pageCount,
    required this.index,
    required this.builder,
    required this.animation,
    required this.duration,
    this.swipeEnabled = true,
    this.onIndexChanged,
    this.onOverscrollNext,
    this.onOverscrollPrev,
    this.controller,
  });

  final int pageCount;
  final int index;
  final Widget Function(BuildContext context, int index) builder;
  final ReaderPageAnim animation;
  final Duration duration;
  final bool swipeEnabled;
  final ValueChanged<int>? onIndexChanged;

  /// 末页继续往后翻、首页继续往前翻时的回调（用于换章）。
  final VoidCallback? onOverscrollNext;
  final VoidCallback? onOverscrollPrev;

  final ReaderPagerController? controller;

  @override
  State<ReaderPager> createState() => _ReaderPagerState();
}

class _ReaderPagerState extends State<ReaderPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: widget.duration);
  late int _index = widget.index.clamp(0, _maxIndex);
  double _progress = 0;
  double _width = 0;
  double _height = 0;

  int get _maxIndex => widget.pageCount <= 0 ? 0 : widget.pageCount - 1;

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < _maxIndex;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant ReaderPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (widget.index != _index && !_anim.isAnimating) {
      _index = widget.index.clamp(0, _maxIndex);
      _progress = 0;
    }
    if (widget.duration != _anim.duration) {
      _anim.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _anim.dispose();
    super.dispose();
  }

  Future<bool> goTo(int target) async {
    if (_anim.isAnimating) return false;
    final clamped = target.clamp(0, _maxIndex);
    if (clamped == _index) return false;
    final ahead = clamped > _index;
    await _animateProgress(ahead ? -1.0 : 1.0);
    if (!mounted) return false;
    setState(() {
      _index = clamped;
      _progress = 0;
    });
    _anim.value = 0;
    widget.onIndexChanged?.call(clamped);
    return true;
  }

  void jumpTo(int target) {
    if (!mounted) return;
    _anim.stop();
    setState(() {
      _index = target.clamp(0, _maxIndex);
      _progress = 0;
    });
    _anim.value = 0;
  }

  Future<void> _animateProgress(double to) {
    final from = _progress;
    final curved = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    final tween = Tween<double>(begin: from, end: to).animate(curved);
    void listener() {
      if (!mounted) return;
      setState(() => _progress = tween.value);
    }

    tween.addListener(listener);
    return _anim.forward(from: 0).whenComplete(() {
      tween.removeListener(listener);
    });
  }

  Future<void> _bounceBack() async {
    if (!mounted) return;
    await _animateProgress(0);
    if (mounted) setState(() => _progress = 0);
  }

  void _onDragStart(DragStartDetails details) {
    if (!widget.swipeEnabled) return;
    _anim.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.swipeEnabled || _width <= 0) return;
    final delta = details.primaryDelta ?? 0;
    var next = _progress + delta / _width;
    // 边界加阻尼，给出「到头了」的手感。
    if (next > 0 && !_hasPrev) next *= 0.28;
    if (next < 0 && !_hasNext) next *= 0.28;
    setState(() => _progress = next.clamp(-1.2, 1.2));
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.swipeEnabled) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_progress > 0) {
      final commit = _progress > 0.28 || velocity > 380;
      if (_hasPrev && commit) {
        // ignore: discarded_futures
        goTo(_index - 1);
      } else if (!_hasPrev && commit && widget.onOverscrollPrev != null) {
        widget.onOverscrollPrev!();
        // ignore: discarded_futures
        _bounceBack();
      } else {
        // ignore: discarded_futures
        _bounceBack();
      }
      return;
    }
    if (_progress < 0) {
      final commit = _progress < -0.28 || velocity < -380;
      if (_hasNext && commit) {
        // ignore: discarded_futures
        goTo(_index + 1);
      } else if (!_hasNext && commit && widget.onOverscrollNext != null) {
        widget.onOverscrollNext!();
        // ignore: discarded_futures
        _bounceBack();
      } else {
        // ignore: discarded_futures
        _bounceBack();
      }
      return;
    }
    if (_progress != 0) {
      // ignore: discarded_futures
      _bounceBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        _height = constraints.maxHeight;
        final target = _progress >= 0 ? _index - 1 : _index + 1;
        final targetValid = target >= 0 && target <= _maxIndex;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: ClipRect(
            child: Stack(
              children: [
                if (targetValid && target != _index)
                  _buildPage(
                    target,
                    readerTurnFrame(
                      progress: _progress,
                      isCurrent: false,
                      isPrev: target < _index,
                      isNext: target > _index,
                      anim: widget.animation,
                    ),
                  ),
                _buildPage(
                  _index,
                  readerTurnFrame(
                    progress: _progress,
                    isCurrent: true,
                    isPrev: false,
                    isNext: false,
                    anim: widget.animation,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPage(int index, ReaderTurnFrame frame) {
    if (index < 0 || index > _maxIndex) return const SizedBox.shrink();
    if (frame.opacity <= 0.001) return const SizedBox.shrink();

    Widget child = widget.builder(context, index);

    if (frame.curl > 0.001) {
      child = _CurlWrapper(progress: frame.curl, child: child);
    }
    if (frame.dim > 0.001) {
      child = Stack(
        fit: StackFit.expand,
        children: [
          child,
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: frame.dim * 0.5),
            ),
          ),
        ],
      );
    }
    if (frame.scale != 1) {
      child = Transform.scale(scale: frame.scale, child: child);
    }
    if (frame.opacity < 0.999) {
      child = Opacity(opacity: frame.opacity.clamp(0.0, 1.0), child: child);
    }
    return Positioned.fill(
      child: Transform.translate(
        offset: Offset(frame.translateX * _width, frame.translateY * _height),
        child: child,
      ),
    );
  }
}

/// 仿真翻页：右侧被卷起，露出下面一页。
class _CurlWrapper extends StatelessWidget {
  const _CurlWrapper({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final keep = (1 - progress).clamp(0.0, 1.0);
    return ClipRect(
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: keep,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 42,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.10 + 0.18 * progress),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
