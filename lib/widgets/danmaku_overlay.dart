import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/player_overlay_theme.dart';
import '../core/bili/api.dart';
import '../core/danmaku/danmaku_merge.dart';

/// 弹幕展示层（滚动弹幕，Canvas 自绘；发送/高级屏蔽留二期）。
///
/// 位置由播放器每帧喂入 [position]；进入（progress 出现）后从右侧划到左侧，
/// 超过屏宽即移除。
///
/// 显示分区参照优酷等主流播放器：**只占画面上部 [rows] 行**，不再铺满整屏；
/// 每条弹幕在生命周期内固定轨道（[DanmakuLaneAllocator]），不再随滚动窗口
/// 进出而跳行。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.enabled = true,
    this.animating = true,
    this.blockWords = const {},
    this.rows = 4,
    this.areaFraction = 0.25,
    this.scrollDuration = const Duration(milliseconds: 8000),
    this.textSize = 16,
    this.opacity = 1,
    this.stroke = true,
    this.mergeSame = true,
  });

  final List<DanmakuItem> items;

  /// 当前播放位置（每帧更新）。
  final Duration position;

  /// 是否显示（关掉弹幕开关时整层不画）。
  final bool enabled;

  /// 是否跑 30fps 重绘 ticker。
  ///
  /// 与 [enabled] 拆开：暂停时仍要显示（冻结在原位），但不必继续空转 setState。
  final bool animating;

  /// 屏蔽词（包含匹配，大小写不敏感）。
  final Set<String> blockWords;

  /// 显示行数（只在画面上部这些行内滚动）。1–10。
  final int rows;

  /// 显示区域占画面高度的比例：顶部 1/4 = 0.25 / 半屏 = 0.5 / 全屏 = 1。
  ///
  /// 与 [rows] 取交集：两者都限制时不越界，小窗不会画到画面外。
  final double areaFraction;

  /// 单条弹幕从右到左的滚动时长（越大越慢）。
  final Duration scrollDuration;

  /// 字号（行高按 1.6 倍推导）。
  final double textSize;

  /// 不透明度 0–1。
  final double opacity;

  /// 是否给文字加描边阴影（浅色画面上保证可读）。
  final bool stroke;

  /// 是否合并窗口内重复的同句弹幕（「+1」刷屏）。
  final bool mergeSame;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  /// 屏蔽判定：委托顶层 [isDanmakuBlocked]（两个播放器共用同一语义）。
  bool _isBlocked(String text) => isDanmakuBlocked(text, widget.blockWords);

  Timer? _ticker;

  late DanmakuLaneAllocator _lanes =
      DanmakuLaneAllocator(rows: widget.rows);

  /// 同句合并缓存：items 是播放器每次拉取后整表替换的新列表，
  /// identity 变一次算一次，不能放进 build 里每帧重算（30fps × 上千条）。
  List<DanmakuItem>? _mergedSource;
  List<DanmakuItem> _merged = const [];

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    // 换集（整表替换）或行数变化：轨道表作废，否则旧集的分配会污染新集。
    if (!identical(old.items, widget.items) || old.rows != widget.rows) {
      _lanes = DanmakuLaneAllocator(rows: widget.rows);
    }
    if (old.enabled != widget.enabled ||
        old.animating != widget.animating ||
        old.items.length != widget.items.length) {
      _syncTicker();
    }
  }

  /// 空闲停表：没有弹幕可画（开关关 / 集为空 / 已暂停）时不再 30fps 空转
  /// setState——安卓连播场景下这是持续的 CPU/电量开销，也与连播崩溃的防御
  /// 相关。暂停时保留画面（position 不再变化 → 冻结在原位）。
  void _syncTicker() {
    final need = widget.enabled &&
        widget.animating &&
        widget.items.isNotEmpty &&
        mounted;
    if (need && _ticker == null) {
      // 30fps 重绘（避免每帧 setState 的开销也够流畅）。
      _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
        if (mounted && widget.enabled && widget.animating) setState(() {});
      });
    } else if (!need && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// 取合并后的条目表（按 items identity + 开关缓存）。
  List<DanmakuItem> _itemsForDisplay() {
    if (!widget.mergeSame) return widget.items;
    if (identical(_mergedSource, widget.items)) return _merged;
    _mergedSource = widget.items;
    _merged = mergeSameDanmaku<DanmakuItem>(
      widget.items,
      offsetOf: (item) => item.progressMs,
      textOf: (item) => item.text,
    );
    return _merged;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final List<DanmakuItem> display = _itemsForDisplay();
    if (display.isEmpty) return const SizedBox.shrink();
    final blocked = widget.blockWords.isEmpty
        ? display
        : display.where((item) => !_isBlocked(item.text)).toList();
    if (blocked.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _DanmakuPainter(
          items: blocked,
          position: widget.position,
          rows: widget.rows,
          areaFraction: widget.areaFraction.clamp(0.05, 1.0),
          lanes: _lanes,
          scrollMs: math.max(1000, widget.scrollDuration.inMilliseconds),
          textStyle: TextStyle(
            color: PlayerOverlayTokens.textPrimary
                .withValues(alpha: widget.opacity.clamp(0.0, 1.0)),
            fontSize: widget.textSize,
            // 描边用双层阴影模拟（Flutter 的 TextStyle 没有 stroke 属性）：
            // 一层贴边保清晰、一层扩散压住浅色画面。
            shadows: widget.stroke
                ? const [
                    Shadow(
                      blurRadius: 1,
                      color: PlayerOverlayTokens.hudFill,
                    ),
                    Shadow(
                      blurRadius: 3,
                      color: PlayerOverlayTokens.hudFill,
                      offset: Offset(1, 1),
                    ),
                  ]
                : const [],
          ),
        ),
      ),
    );
  }
}

/// 轨道分配器：给每条弹幕一个**固定**轨道。
///
/// 旧实现用「active 列表下标 % 8」：窗口进出会让下标整体平移，同一条弹幕
/// 于是在轨道间跳行。这里按条目 id 缓存轨道，分配时优先挑「已空闲」的轨道，
/// 都占着就挑最早空闲的那条——同屏不追尾，且 id 恒定 → 轨道恒定。
class DanmakuLaneAllocator {
  DanmakuLaneAllocator({required this.rows}) : assert(rows > 0);

  /// 显示行数。
  final int rows;

  static const int _pruneAt = 600;
  static const int _keepRecent = 200;

  final Map<String, int> _laneOf = <String, int>{};
  final List<int> _freeAtMs = <int>[];

  /// 当前分配到第几轨（供测试断言）。
  @visibleForTesting
  Map<String, int> get debugLaneOf => Map<String, int>.unmodifiable(_laneOf);

  /// 取一条弹幕的轨道（必要时新分配）。[gapMs] 是该轨被占用的最短时长。
  ///
  /// [key] 用「出现时间 + 文本」做稳定身份：bili 弹幕条目没有 id 字段，而
  /// 同一集两次拉到同一页时同一条弹幕必须映射到同一条轨道。
  int laneFor(String key, {required int progressMs, required int gapMs}) {
    final int? cached = _laneOf[key];
    if (cached != null && cached >= 0 && cached < rows) return cached;

    if (_freeAtMs.length != rows) {
      _freeAtMs
        ..clear()
        ..addAll(List<int>.filled(rows, -0x3FFFFFFFFFFFFF));
    }
    var best = 0;
    for (var i = 0; i < rows; i++) {
      if (_freeAtMs[i] <= progressMs) {
        best = i;
        break;
      }
      if (_freeAtMs[i] < _freeAtMs[best]) best = i;
    }
    _laneOf[key] = best;
    _freeAtMs[best] = progressMs + gapMs;
    _prune();
    return best;
  }

  /// 长视频里表会一直长：只保留最近 [ _keepRecent ] 条（仍在屏上的就在其中）。
  void _prune() {
    if (_laneOf.length <= _pruneAt) return;
    final List<String> keys = _laneOf.keys.toList(growable: false);
    final Set<String> keep = keys
        .sublist(keys.length - _keepRecent)
        .toSet();
    _laneOf.removeWhere((key, _) => !keep.contains(key));
  }
}

const int _scrollMs = 8000;

/// 弹幕屏蔽判定（顶层函数，便于单测与两个播放器共用同一语义）：
/// `re:` 前缀按正则（非法正则跳过），其余大小写不敏感的包含匹配。
bool isDanmakuBlocked(String text, Set<String> blockWords) {
  if (blockWords.isEmpty) return false;
  final lower = text.toLowerCase();
  for (final w in blockWords) {
    if (w.startsWith('re:')) {
      final pattern = w.substring(3);
      final regex = _blockedRegexCache.putIfAbsent(pattern, () {
        try {
          return RegExp(pattern, caseSensitive: false);
        } on FormatException {
          return null;
        }
      });
      if (regex != null && regex.hasMatch(text)) return true;
    } else if (lower.contains(w.toLowerCase())) {
      return true;
    }
  }
  return false;
}

final _blockedRegexCache = <String, RegExp?>{};

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.items,
    required this.position,
    required this.textStyle,
    required this.rows,
    required this.areaFraction,
    required this.lanes,
    required this.scrollMs,
  });

  final List<DanmakuItem> items;
  final Duration position;
  final TextStyle textStyle;

  /// 显示行数上限。
  final int rows;

  /// 显示区域占画面高度的比例（0–1）。
  final double areaFraction;

  /// 固定轨道分配器（State 持有，跨帧稳定）。
  final DanmakuLaneAllocator lanes;

  /// 滚动时长（毫秒）。
  final int scrollMs;

  static final Map<String, TextPainter> _painterCache = {};

  @override
  void paint(Canvas canvas, Size size) {
    final posMs = position.inMilliseconds;
    final double trackHeight = _trackHeight;
    // 行数上限同时受画面高度与「显示区域」比例约束（顶部 1/4 / 半屏 / 全屏），
    // 小窗塞不下 10 行时也不画到画面外。
    final double usableHeight = math.max(1, size.height * areaFraction - _topPad);
    final int visibleRows =
        math.max(1, math.min(rows, (usableHeight / trackHeight).floor()));
    // 轨道占用间隔：至少 900ms，密集时按行数摊薄，避免同轨追尾。
    final int gapMs = math.max(900, scrollMs ~/ math.max(1, rows));
    for (final item in items) {
      final delta = posMs - item.progressMs;
      // 只画 [pos - scrollMs, pos] 窗口内的弹幕（进入即开始滚动）。
      if (delta < 0 || delta > scrollMs) continue;
      final lane = lanes.laneFor(
        '${item.progressMs}|${item.text}',
        progressMs: item.progressMs,
        gapMs: gapMs,
      );
      if (lane >= visibleRows) continue;
      final TextPainter painter = _painterFor(item.text);
      final double progress = delta / scrollMs;
      final double x = size.width - progress * (size.width + painter.width);
      if (x + painter.width < 0) continue;
      final double y = _topPad + lane * trackHeight;
      painter.paint(canvas, Offset(x, y));
    }
  }

  /// 顶部留白：弹幕不贴画面边缘。
  static const double _topPad = 8;

  double get _trackHeight => textStyle.fontSize! * 1.6;

  TextPainter _painterFor(String text) {
    // 样式参与 key：字号/透明度改了必须重排（透明度影响颜色，不影响宽度，
    // 但共用一份 TextPainter 时颜色会被旧值钉死）。
    final String key =
        '${textStyle.fontSize}|${textStyle.color?.a}|$text';
    if (_painterCache.length > 300) _painterCache.clear();
    return _painterCache.putIfAbsent(key, () {
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

/// 默认滚动时长（旧常量，保留给调用方做「标准档」参照）。
const Duration kDanmakuDefaultScroll = Duration(milliseconds: _scrollMs);
