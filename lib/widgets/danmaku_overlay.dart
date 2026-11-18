import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/player_overlay_theme.dart';
import '../core/bili/api.dart';
import '../core/danmaku/danmaku_merge.dart';

/// 弹幕展示层（滚动弹幕，Canvas 自绘；发送/高级屏蔽留二期）。
///
/// 性能模型（「零 rebuild」管线）：
/// - 播放器位置只作**基准**，每帧位置由 [Ticker] 解析式插值后写进
///   [ValueNotifier]，[CustomPaint] 的 painter 通过 `repaint` 直接订阅；
///   位置前进**不触发任何 widget rebuild / layout**。
/// - 屏蔽词与同句合并结果按 `items` 与屏蔽词集合缓存，不在每帧重算。
/// - 暂停时写回基准值（同值不通知）→ 零重绘。
/// - 位置误差 ≤150ms 直接采纳基准；150ms–1s 在 250ms 内线性吸收；
///   >1s（seek/换线）硬对齐，避免弹幕整屏瞬移。
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
    this.rate = 1.0,
  });

  final List<DanmakuItem> items;

  /// 播放器给出的**基准**位置（低频、可以每秒一次）。
  ///
  /// 弹幕层内部按 Ticker 插值到每一帧；这里的值只用于校正，
  /// 不需要（也不应该）每帧更新。
  final Duration position;

  /// 是否显示（关掉弹幕开关时整层不画）。
  final bool enabled;

  /// 是否推进（暂停时为 false：画面冻结、Ticker 停止、零重绘）。
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

  /// 播放倍率：位置插值按它缩放，默认 1.0。
  final double rate;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// 当前弹幕时钟。painter 通过 `repaint` 订阅，不经过 build。
  final ValueNotifier<Duration> _clock = ValueNotifier<Duration>(Duration.zero);

  /// 基准位置，以及记录它时的 Ticker elapsed。
  Duration _base = Duration.zero;
  Duration _baseAtTick = Duration.zero;
  Duration _lastTick = Duration.zero;

  /// 误差吸收：在 [danmakuCorrectionSpan] 内把 [_correction] 线性衰减到 0。
  Duration _correction = Duration.zero;
  Duration _correctionAt = Duration.zero;

  late DanmakuLaneAllocator _lanes = DanmakuLaneAllocator(rows: widget.rows);
  late TextStyle _textStyle = _buildTextStyle();

  // 过滤结果缓存：items 与屏蔽词都没变就不重算（每帧 O(N) 过滤曾是主要开销）。
  List<DanmakuItem>? _viewSource;
  Set<String>? _viewWords;
  List<DanmakuItem> _view = const [];

  @override
  void initState() {
    super.initState();
    _base = widget.position;
    _clock.value = _base;
    _syncTicker();
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    // 换集（整表替换）或行数变化：轨道表作废，否则旧集的分配会污染新集。
    if (!identical(old.items, widget.items) || old.rows != widget.rows) {
      _lanes = DanmakuLaneAllocator(rows: widget.rows);
    }
    if (old.textSize != widget.textSize ||
        old.opacity != widget.opacity ||
        old.stroke != widget.stroke) {
      _textStyle = _buildTextStyle();
      _DanmakuPainter.invalidateStyleCache();
    }
    if (old.position != widget.position) {
      _absorb(widget.position);
    }
    if (old.enabled != widget.enabled ||
        old.animating != widget.animating ||
        old.items.length != widget.items.length) {
      _syncTicker();
    }
  }

  TextStyle _buildTextStyle() => TextStyle(
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
      );

  /// 空闲停表：没有弹幕可画（开关关 / 集为空 / 已暂停）时不再跑 Ticker。
  void _syncTicker() {
    final need = widget.enabled &&
        widget.animating &&
        widget.items.isNotEmpty &&
        mounted;
    if (need && !_ticker.isActive) {
      // Ticker 重开后 elapsed 归零：基准换到播放器当前值，避免跳回旧位置。
      _base = widget.position;
      _baseAtTick = Duration.zero;
      _correction = Duration.zero;
      _clock.value = _base;
      _ticker.start();
    } else if (!need && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    _lastTick = elapsed;
    if (!widget.animating) {
      _clock.value = _base;
      return;
    }
    var pos = _interpolate(elapsed);
    final corr = _correction;
    if (corr != Duration.zero) {
      final span = danmakuCorrectionSpan.inMicroseconds;
      final t = span <= 0
          ? 1.0
          : (elapsed - _correctionAt).inMicroseconds / span;
      if (t >= 1.0) {
        _correction = Duration.zero;
      } else {
        pos += Duration(
            microseconds: (corr.inMicroseconds * (1.0 - t)).round());
      }
    }
    _clock.value = pos;
  }

  /// 按 Ticker 时间解析式插值：位置 = 基准 + (tick - 基准时刻) × 倍率。
  Duration _interpolate(Duration tickNow) => danmakuClockAt(
        base: _base,
        baseAtTick: _baseAtTick,
        tickNow: tickNow,
        playing: widget.animating,
        rate: widget.rate,
      );

  /// 播放器给了新位置：小误差刷新基准，中误差线性吸收，大跳变硬对齐。
  void _absorb(Duration measured) {
    final predicted = _interpolate(_lastTick);
    final plan =
        planDanmakuCorrection(measured: measured, predicted: predicted);
    if (plan.snap) {
      _base = measured;
      _baseAtTick = _lastTick;
      _correction = Duration.zero;
      _clock.value = measured;
      return;
    }
    if (plan.amount == Duration.zero) {
      _base = measured;
      _baseAtTick = _lastTick;
      _correction = Duration.zero;
      _clock.value = _interpolate(_lastTick);
      return;
    }
    _correction = plan.amount;
    _correctionAt = _lastTick;
  }

  /// 取当前要画的条目（合并 + 屏蔽），结果按输入缓存。
  List<DanmakuItem> _visibleItems() {
    if (identical(_viewSource, widget.items) &&
        setEquals(_viewWords, widget.blockWords)) {
      return _view;
    }
    _viewSource = widget.items;
    _viewWords =
        widget.blockWords.isEmpty ? null : Set<String>.of(widget.blockWords);
    _view = filterDanmakuItems(
      items: widget.items,
      blockWords: widget.blockWords,
      mergeSame: widget.mergeSame,
    );
    return _view;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final List<DanmakuItem> display = _visibleItems();
    if (display.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _DanmakuPainter(
            items: display,
            clock: _clock,
            textStyle: _textStyle,
            rows: widget.rows,
            areaFraction: widget.areaFraction.clamp(0.05, 1.0),
            lanes: _lanes,
            scrollMs: math.max(1000, widget.scrollDuration.inMilliseconds),
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

/// 位置误差超过它就直接硬对齐（seek / 换线 / 慢速拖进度）。
const Duration danmakuHardSeek = Duration(seconds: 1);

/// 位置误差小于它视为噪声，直接采纳基准（肉眼不可见）。
const Duration danmakuIgnoreError = Duration(milliseconds: 150);

/// 中等误差的线性吸收窗口。
const Duration danmakuCorrectionSpan = Duration(milliseconds: 250);

/// 弹幕时钟的解析式插值：位置 = 基准 + (tick - 基准时刻) × 倍率。
///
/// 播放器位置事件是低频的（约 1 秒一次），逐帧位置必须自己算；
/// 暂停时直接返回基准（同值写入 ValueNotifier 不会触发重绘）。
Duration danmakuClockAt({
  required Duration base,
  required Duration baseAtTick,
  required Duration tickNow,
  required bool playing,
  required double rate,
}) {
  if (!playing) return base;
  final double r = rate <= 0 ? 1.0 : rate;
  final Duration delta = tickNow - baseAtTick;
  return base + Duration(microseconds: (delta.inMicroseconds * r).round());
}

/// 合并同句并剔除屏蔽词后的待画条目。
///
/// 抽成顶层函数：State 只在 items / 屏蔽词变化时调用一次，
/// 不再每帧执行（此前是 30fps × 全量过滤）。
List<DanmakuItem> filterDanmakuItems({
  required List<DanmakuItem> items,
  required Set<String> blockWords,
  required bool mergeSame,
}) {
  var list = items;
  if (mergeSame) {
    list = mergeSameDanmaku<DanmakuItem>(
      list,
      offsetOf: (item) => item.progressMs,
      textOf: (item) => item.text,
    );
  }
  if (blockWords.isNotEmpty) {
    list = list
        .where((item) => !isDanmakuBlocked(item.text, blockWords))
        .toList();
  }
  return list;
}

/// 一次位置校正的计划。
class DanmakuCorrection {
  const DanmakuCorrection({this.snap = false, this.amount = Duration.zero});

  /// true 表示直接把时钟对齐到播放器位置（大跳变）。
  final bool snap;

  /// 需要线性吸收的误差量（[snap] 为 false 且非零时有效）。
  final Duration amount;

  static const DanmakuCorrection none = DanmakuCorrection();
}

/// 根据预测位置与实际位置的误差，决定「忽略 / 线性吸收 / 硬对齐」。
DanmakuCorrection planDanmakuCorrection({
  required Duration measured,
  required Duration predicted,
}) {
  final Duration err = measured - predicted;
  final int abs = err.inMicroseconds.abs();
  if (abs > danmakuHardSeek.inMicroseconds) {
    return const DanmakuCorrection(snap: true);
  }
  if (abs <= danmakuIgnoreError.inMicroseconds) {
    return DanmakuCorrection.none;
  }
  return DanmakuCorrection(amount: err);
}

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
    required this.clock,
    required this.textStyle,
    required this.rows,
    required this.areaFraction,
    required this.lanes,
    required this.scrollMs,
  }) : super(repaint: clock);

  final List<DanmakuItem> items;

  /// 弹幕时钟：painter 直接订阅它，每帧只重绘，不重建 widget。
  final ValueListenable<Duration> clock;
  final TextStyle textStyle;

  /// 显示行数上限。
  final int rows;

  /// 显示区域占画面高度的比例（0–1）。
  final double areaFraction;

  /// 固定轨道分配器（State 持有，跨帧稳定）。
  final DanmakuLaneAllocator lanes;

  /// 滚动时长（毫秒）。
  final int scrollMs;

  static final Map<String, TextPainter> _painters = <String, TextPainter>{};
  static int? _styleHash;

  /// 样式变化时由 State 调用：旧样式的排版结果必须作废。
  static void invalidateStyleCache() {
    _painters.clear();
    _styleHash = null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final posMs = clock.value.inMilliseconds;
    final double trackHeight = _trackHeight;
    // 行数上限同时受画面高度与「显示区域」比例约束（顶部 1/4 / 半屏 / 全屏），
    // 小窗塞不下 10 行时也不画到画面外。
    final double usableHeight =
        math.max(1, size.height * areaFraction - _topPad);
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
    // 缓存键只用文本：样式变化由 invalidateStyleCache() 统一作废，
    // 避免每帧、每条弹幕都拼一次 '$fontSize|$alpha|$text'。
    final int hash = textStyle.hashCode;
    if (_styleHash != hash) {
      _painters.clear();
      _styleHash = hash;
    }
    if (_painters.length > 300) _painters.clear();
    return _painters.putIfAbsent(text, () {
      final tp = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp;
    });
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) =>
      !identical(oldDelegate.items, items) ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.rows != rows ||
      oldDelegate.areaFraction != areaFraction ||
      !identical(oldDelegate.lanes, lanes) ||
      oldDelegate.scrollMs != scrollMs;
}

/// 默认滚动时长（旧常量，保留给调用方做「标准档」参照）。
const Duration kDanmakuDefaultScroll = Duration(milliseconds: _scrollMs);
