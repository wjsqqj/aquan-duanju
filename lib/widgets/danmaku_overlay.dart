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
    this.resetEpoch = 0,
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

  /// 显式重置令牌：seek / 换集 / 换线时由播放器递增。
  ///
  /// 只有它变化时才允许时间轴回退到播放器位置；单纯的位置事件回退
  /// （缓冲、切轨、事件乱序）一律按抖动处理，否则已飘出屏幕的弹幕
  /// 会被拉回来「闪现」。
  final int resetEpoch;

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

  /// 上一次真正写进 [_clock] 的位置：时间轴只进不退（硬对齐除外）。
  Duration _lastClock = Duration.zero;

  /// 写入时钟的最小间隔（30fps）。
  static const Duration _frameBudget = Duration(milliseconds: 33);

  /// 上一次真正写 [_clock] 的 Ticker 时刻（节流基准，与 [_lastTick] 区分：
  /// 后者每帧都更新，是插值基准）。
  Duration _lastWriteTick = Duration.zero;

  /// 当前弹幕时钟（测试断言用）。
  @visibleForTesting
  Duration get debugClock => _clock.value;

  /// 误差吸收：在 [danmakuCorrectionSpan] 内把 [_correction] 线性衰减到 0。
  Duration _correction = Duration.zero;
  Duration _correctionAt = Duration.zero;

  late DanmakuLaneAllocator _lanes = DanmakuLaneAllocator(rows: widget.rows);
  late TextStyle _textStyle = _buildTextStyle();

  // 过滤结果缓存：items、屏蔽词、合并开关都没变就不重算（每帧 O(N) 过滤曾是
  // 主要开销）。合并开关漏进缓存键会导致切开关后画面不刷新，这里一并纳管。
  List<DanmakuItem>? _viewSource;
  Set<String>? _viewWords;
  bool _viewMergeSame = true;
  List<DanmakuRenderItem> _view = const [];

  // 帧快照缓存：排序 + 二分索引只在这三项变化时重建。
  List<DanmakuRenderItem>? _frameSource;
  int _frameScrollMs = 0;
  DanmakuFrame? _frame;

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
    // 换集（整表替换）、行数变化、屏蔽词或合并开关变化：轨道表作废。
    // 后两者的必要性：轨道键是「帧内下标」，而 frame 基于过滤后的列表构建；
    // 过滤结果一变，同一个下标就指向另一条弹幕，旧轨道表会把 A 的轨道套给 B
    // （表现为改设置瞬间弹幕跳行/同轨重叠）。
    if (!identical(old.items, widget.items) ||
        old.rows != widget.rows ||
        !setEquals(old.blockWords, widget.blockWords) ||
        old.mergeSame != widget.mergeSame) {
      _lanes = DanmakuLaneAllocator(rows: widget.rows);
    }
    if (old.textSize != widget.textSize ||
        old.opacity != widget.opacity ||
        old.stroke != widget.stroke) {
      _textStyle = _buildTextStyle();
      _DanmakuPainter.invalidateStyleCache();
    }
    if (old.resetEpoch != widget.resetEpoch) {
      // 显式 seek / 换集：允许时间轴回退到播放器位置。
      _resetTo(widget.position);
    } else if (old.position != widget.position) {
      _absorb(widget.position);
    }
    if (old.animating != widget.animating) {
      if (widget.animating) {
        // 恢复播放：以播放器位置重新起算，允许一次基准重置（暂停期间 Ticker
        // 仍在跑，elapsed 已前进，不能沿用旧基准）。
        _base = widget.position;
        _baseAtTick = _lastTick;
        _correction = Duration.zero;
        _lastClock = _base;
        _clock.value = _base;
      } else {
        // 进入暂停：冻结在当前显示位置。
        _base = _lastClock;
        _baseAtTick = _lastTick;
        _correction = Duration.zero;
      }
      _syncTicker();
    } else if (old.enabled != widget.enabled ||
        old.items.length != widget.items.length) {
      _syncTicker();
    }
  }

  TextStyle _buildTextStyle() => TextStyle(
        color: PlayerOverlayTokens.textPrimary
            .withValues(alpha: widget.opacity.clamp(0.0, 1.0)),
        fontSize: widget.textSize,
        // 描边用 4 向实心偏移模拟（Flutter 的 TextStyle 没有 stroke 属性）。
        // 旧实现的 blurRadius 1 + 3 会把文字边缘糊成一团光晕——密集时肉眼看
        // 就是「弹幕很模糊」；实心偏移边缘锐利，且少两次模糊合成更省 GPU。
        shadows: widget.stroke
            ? const [
                Shadow(
                  blurRadius: 0,
                  color: PlayerOverlayTokens.hudFill,
                  offset: Offset(-1, 0),
                ),
                Shadow(
                  blurRadius: 0,
                  color: PlayerOverlayTokens.hudFill,
                  offset: Offset(1, 0),
                ),
                Shadow(
                  blurRadius: 0,
                  color: PlayerOverlayTokens.hudFill,
                  offset: Offset(0, -1),
                ),
                Shadow(
                  blurRadius: 0,
                  color: PlayerOverlayTokens.hudFill,
                  offset: Offset(0, 1),
                ),
              ]
            : const [],
      );

  /// Ticker 只由「开关打开 + 有弹幕可画 + 已挂载」决定，**不再依赖 animating**。
  ///
  /// 引擎的播放态会短暂抖动（缓冲、切轨、连播间隙），一抖就停表的话时钟不再
  /// 前进，屏上的弹幕会陆续过期消失——这正是「弹幕先少后没」的成因。
  /// 暂停时不推进时钟（画面冻结），但 Ticker 继续跑，代价是每帧一次同值写入
  /// （ValueNotifier 同值不通知，不触发重绘）。
  void _syncTicker() {
    final need = widget.enabled && widget.items.isNotEmpty && mounted;
    if (need && !_ticker.isActive) {
      // Ticker 重开后 elapsed 归零：基准换到播放器当前值，避免跳回旧位置。
      _base = widget.position;
      _baseAtTick = Duration.zero;
      _correction = Duration.zero;
      _lastClock = _base;
      _clock.value = _base;
      // 节流基准必须一起归零：elapsed 从 0 重新计时，若沿用上一轮累计值
      // （例如关弹幕前已跑 5 分钟）`elapsed - _lastWriteTick` 恒为负，
      // 时钟永不写入 → 重新打开弹幕后整层静止。
      _lastWriteTick = Duration.zero;
      _ticker.start();
    } else if (!need && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    _lastTick = elapsed;
    if (!widget.animating) {
      // 暂停：冻结在当前位置，不写时钟（同值也不会通知）。
      return;
    }
    // 30fps 节流：Ticker 跑满刷新率时（120Hz = 每秒 120 次全量重绘），密集弹幕
    // 段会把主线程预算吃光，表现为画面一顿一顿。插值公式不变，只是把「写时钟」
    // 的频率压到肉眼足够顺滑的 30fps。
    if (elapsed - _lastWriteTick < _frameBudget) return;
    _lastWriteTick = elapsed;
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
    // 时间轴只进不退：位置事件的抖动不允许把弹幕往回拖（硬对齐另行处理）。
    if (pos < _lastClock) pos = _lastClock;
    _lastClock = pos;
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

  /// 显式重置：seek / 换集 / 换线时把时间轴直接放到播放器位置（允许回退）。
  void _resetTo(Duration position) {
    _base = position;
    _baseAtTick = _lastTick;
    _correction = Duration.zero;
    _lastClock = position;
    _clock.value = position;
  }

  /// 播放器给了新位置：基准一律对齐 measured，用 [_correction] 把屏幕上的
  /// 当前位置平滑带过去。
  ///
  /// 旧实现的中误差分支只设 correction、不推进基准，于是每秒都要重新补偿
  /// 一次（表现为弹幕一顿一顿、看起来左右晃）。现在基准永远跟着播放器走，
  /// 只用一个衰减量把显示位置接上去，且时间轴单调不回退。
  void _absorb(Duration measured) {
    if (!widget.animating) {
      // 暂停：只对齐基准，画面保持冻结。
      _base = measured;
      _baseAtTick = _lastTick;
      _correction = Duration.zero;
      return;
    }
    final predicted = _interpolate(_lastTick);
    final plan =
        planDanmakuCorrection(measured: measured, predicted: predicted);
    if (plan.snap) {
      if (measured < _lastClock) {
        // 位置事件回退（缓冲、切轨、事件乱序）：这不是 seek，保持时间轴单调，
        // 否则已经飘出屏幕的弹幕会被拉回来「闪现」。真正的 seek 由
        // resetEpoch 显式通知，不走这里。
        _base = _lastClock;
        _baseAtTick = _lastTick;
        _correction = Duration.zero;
        return;
      }
      _base = measured;
      _baseAtTick = _lastTick;
      _correction = Duration.zero;
      _lastClock = measured;
      _clock.value = measured;
      return;
    }
    final current = _lastClock;
    if (current >= measured) {
      // 显示位置已追上或超前：保持单调，以当前位置为新基准。
      _base = current;
      _baseAtTick = _lastTick;
      _correction = Duration.zero;
      return;
    }
    // 落后：基准对齐 measured，correction 为负值、逐步归零 → 平滑追上。
    _base = measured;
    _baseAtTick = _lastTick;
    _correction = current - measured;
    _correctionAt = _lastTick;
  }

  /// 取当前要画的条目（合并 + 屏蔽），结果按输入缓存。
  List<DanmakuRenderItem> _visibleItems() {
    if (identical(_viewSource, widget.items) &&
        _viewMergeSame == widget.mergeSame &&
        setEquals(_viewWords, widget.blockWords)) {
      return _view;
    }
    _viewSource = widget.items;
    _viewMergeSame = widget.mergeSame;
    _viewWords =
        widget.blockWords.isEmpty ? null : Set<String>.of(widget.blockWords);
    _view = filterDanmakuItems(
      items: widget.items,
      blockWords: widget.blockWords,
      mergeSame: widget.mergeSame,
    );
    return _view;
  }

  /// 帧快照：把「排序 + 二分索引」从每帧绘制里挪到列表变化时做一次。
  DanmakuFrame _frameFor(List<DanmakuRenderItem> display, int scrollMs) {
    final cached = _frame;
    if (cached != null &&
        identical(_frameSource, display) &&
        _frameScrollMs == scrollMs) {
      return cached;
    }
    _frameSource = display;
    _frameScrollMs = scrollMs;
    return _frame = DanmakuFrame.build(display, scrollMs);
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
    final List<DanmakuRenderItem> display = _visibleItems();
    if (display.isEmpty) return const SizedBox.shrink();
    final int scrollMs = math.max(1000, widget.scrollDuration.inMilliseconds);
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _DanmakuPainter(
            frame: _frameFor(display, scrollMs),
            clock: _clock,
            textStyle: _textStyle,
            rows: widget.rows,
            areaFraction: widget.areaFraction.clamp(0.05, 1.0),
            lanes: _lanes,
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

  final Map<Object, int> _laneOf = <Object, int>{};
  final List<int> _freeAtMs = <int>[];

  /// 当前分配到第几轨（供测试断言）。
  @visibleForTesting
  Map<Object, int> get debugLaneOf => Map<Object, int>.unmodifiable(_laneOf);

  /// 取一条弹幕的轨道（必要时新分配）。[gapMs] 是该轨被占用的最短时长。
  ///
  /// [key] 是稳定身份：生产路径传**帧快照里的条目下标**（int，零分配零哈希），
  /// 测试/外部仍可传「出现时间 + 文本」字符串。同一帧内下标恒定 → 轨道恒定。
  int laneFor(Object key, {required int progressMs, required int gapMs}) {
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
    final List<Object> keys = _laneOf.keys.toList(growable: false);
    final Set<Object> keep = keys
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

/// 一条待绘制的弹幕：展示文本已经定稿（同句合并时带「×N」后缀）。
///
/// 与 `bili.DanmakuItem` 分开的原因：展示文本要在**进入绘制管线之前**拼好，
/// 绘制期（30fps × 屏上条数）不再做任何字符串拼接。
class DanmakuRenderItem {
  const DanmakuRenderItem({
    required this.progressMs,
    required this.text,
    this.repeat = 1,
  });

  /// 弹幕出现的播放进度（毫秒），也是二分索引的键。
  final int progressMs;

  /// 最终展示文本（已含「×N」，已剔除屏蔽词）。
  final String text;

  /// 合并了几条（1 = 未合并）。
  final int repeat;
}

/// 合并同句并剔除屏蔽词后的待画条目。
///
/// 抽成顶层函数：State 只在 items / 屏蔽词 / 合并开关变化时调用一次，
/// 不再每帧执行（此前是 30fps × 全量过滤）。
///
/// 合并开启时**不再丢弃**重复句，而是在最早一条上累加并展示「×N」——
/// 观众刷「+1」时既压住视觉噪音，又保留「很多人也在说」的信息量。
List<DanmakuRenderItem> filterDanmakuItems({
  required List<DanmakuItem> items,
  required Set<String> blockWords,
  required bool mergeSame,
}) {
  final List<DanmakuRenderItem> out = <DanmakuRenderItem>[];
  if (mergeSame) {
    for (final counted in mergeSameDanmakuCounted<DanmakuItem>(
      items,
      offsetOf: (item) => item.progressMs,
      textOf: (item) => item.text,
    )) {
      final String text = counted.item.text;
      if (isDanmakuBlocked(text, blockWords)) continue;
      out.add(DanmakuRenderItem(
        progressMs: counted.item.progressMs,
        text: counted.repeat > 1 ? '$text ×${counted.repeat}' : text,
        repeat: counted.repeat,
      ));
    }
    return out;
  }
  for (final item in items) {
    if (isDanmakuBlocked(item.text, blockWords)) continue;
    out.add(DanmakuRenderItem(progressMs: item.progressMs, text: item.text));
  }
  return out;
}

/// 一帧的只读快照：排序后的条目 + 出现时间的二分索引。
///
/// 旧实现每帧 `for (final item in items)` 全表扫描（实测一集 8000+ 条，
/// 120Hz 屏上等于每秒近百万人次迭代）。改成二分后，绘制成本只与
/// 「屏上条数」相关，与「本集总条数」无关。
class DanmakuFrame {
  DanmakuFrame._(this.items, this.starts, this.scrollMs);

  final List<DanmakuRenderItem> items;

  /// `items[i].progressMs`，升序（二分用）。
  final Int32List starts;

  final int scrollMs;

  static DanmakuFrame build(List<DanmakuRenderItem> source, int scrollMs) {
    List<DanmakuRenderItem> items = source;
    for (var i = 1; i < items.length; i++) {
      if (items[i].progressMs < items[i - 1].progressMs) {
        items = List<DanmakuRenderItem>.of(source)
          // 次级键用文本：`List.sort` 不稳定，同一毫秒的多条若换位，
          // 下标轨道键会让它们整体跳一次行。
          ..sort((a, b) {
            final int byTime = a.progressMs.compareTo(b.progressMs);
            return byTime != 0 ? byTime : a.text.compareTo(b.text);
          });
        break;
      }
    }
    final Int32List starts = Int32List(items.length);
    for (var i = 0; i < items.length; i++) {
      starts[i] = items[i].progressMs;
    }
    return DanmakuFrame._(items, starts, scrollMs);
  }
}

/// 可见窗口 `[pos - scrollMs, pos]` 对应的下标区间（左闭右开）。
///
/// [starts] 必须升序。暴露成顶层函数便于单测直接对照线性扫描。
({int start, int end}) danmakuWindow(
  Int32List starts,
  int posMs,
  int scrollMs,
) {
  final int from = posMs - scrollMs;
  // lowerBound(from)：第一个 >= from 的下标。
  var lo = 0;
  var hi = starts.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (starts[mid] < from) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final int start = lo;
  // upperBound(posMs)：第一个 > posMs 的下标。
  lo = start;
  hi = starts.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (starts[mid] <= posMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return (start: start, end: lo);
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
    required this.frame,
    required this.clock,
    required this.textStyle,
    required this.rows,
    required this.areaFraction,
    required this.lanes,
  }) : super(repaint: clock);

  /// 帧快照（排序 + 二分索引），由 State 缓存，绘制期只读。
  final DanmakuFrame frame;

  /// 弹幕时钟：painter 直接订阅它，每帧只重绘，不重建 widget。
  final ValueListenable<Duration> clock;
  final TextStyle textStyle;

  /// 显示行数上限。
  final int rows;

  /// 显示区域占画面高度的比例（0–1）。
  final double areaFraction;

  /// 固定轨道分配器（State 持有，跨帧稳定）。
  final DanmakuLaneAllocator lanes;

  static final Map<String, TextPainter> _painters = <String, TextPainter>{};
  static int? _styleHash;

  /// 文本排版缓存上限：超限按插入顺序淘汰最早 25%，**不再整表清空**。
  /// 旧实现 `if (length > 300) clear()` 会让密集段反复全量重新 layout。
  static const int _painterCacheMax = 1200;

  /// 样式变化时由 State 调用：旧样式的排版结果必须作废。
  static void invalidateStyleCache() {
    _painters.clear();
    _styleHash = null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final int posMs = clock.value.inMilliseconds;
    final int scrollMs = frame.scrollMs;
    final double trackHeight = _trackHeight;
    // 行数上限同时受画面高度与「显示区域」比例约束（顶部 1/4 / 半屏 / 全屏），
    // 小窗塞不下 10 行时也不画到画面外。
    final double usableHeight =
        math.max(1, size.height * areaFraction - _topPad);
    final int visibleRows =
        math.max(1, math.min(rows, (usableHeight / trackHeight).floor()));
    // 二分出 [pos - scrollMs, pos] 的窗口：绘制成本只与屏上条数相关，
    // 与本集总条数无关（旧实现在 8000 条的集上每帧全表扫描）。
    final ({int start, int end}) window =
        danmakuWindow(frame.starts, posMs, scrollMs);
    if (window.start >= window.end) return;

    final int styleHash = textStyle.hashCode;
    if (_styleHash != styleHash) {
      _painters.clear();
      _styleHash = styleHash;
    }

    // 只在本层显示区内绘制：显示区通常只有顶部 25%，不裁剪会让描边与文字
    // 在整屏 overdraw。
    final Rect clip = Rect.fromLTWH(
      0,
      0,
      size.width,
      math.min(size.height, _topPad + visibleRows * trackHeight),
    );
    canvas.save();
    canvas.clipRect(clip);

    final List<DanmakuRenderItem> items = frame.items;
    for (var i = window.start; i < window.end; i++) {
      final DanmakuRenderItem item = items[i];
      final int delta = posMs - item.progressMs;
      if (delta < 0 || delta > scrollMs) continue;
      final TextPainter painter = _painterFor(item.text);
      if (painter.width <= 0) continue;
      // 占轨时长按「这条弹幕完全进入画面」所需时间算（宽度占比）+ 两字间距：
      // 短句几乎不占轨，长句才占。固定间隔（旧实现 900ms / 更早的 2000ms）
      // 会让密集段大量弹幕分不到轨道而被丢弃——表现为「弹幕只有一点点」。
      final int occupyMs = (((painter.width + trackHeight * 2) /
                  (size.width + painter.width)) *
              scrollMs)
          .round()
          .clamp(200, scrollMs);
      // 轨道键用帧内下标（int）：同一帧内稳定，省掉每帧字符串拼接与哈希。
      final int lane = lanes.laneFor(
        i,
        progressMs: item.progressMs,
        gapMs: occupyMs,
      );
      if (lane >= visibleRows) continue;
      final double progress = delta / scrollMs;
      final double x = size.width - progress * (size.width + painter.width);
      if (x + painter.width < 0) continue;
      final double y = _topPad + lane * trackHeight;
      painter.paint(canvas, Offset(x, y));
    }
    canvas.restore();
  }

  /// 顶部留白：弹幕不贴画面边缘。
  static const double _topPad = 8;

  double get _trackHeight => textStyle.fontSize! * 1.6;

  TextPainter _painterFor(String text) {
    // 缓存键只用文本：样式变化由 _styleHash 统一作废。
    final TextPainter? cached = _painters[text];
    if (cached != null) return cached;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    if (_painters.length >= _painterCacheMax) {
      final int drop = (_painterCacheMax ~/ 4) + 1;
      final List<String> victims =
          _painters.keys.take(drop).toList(growable: false);
      for (final String key in victims) {
        _painters.remove(key);
      }
    }
    _painters[text] = tp;
    return tp;
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) =>
      !identical(oldDelegate.frame, frame) ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.rows != rows ||
      oldDelegate.areaFraction != areaFraction ||
      !identical(oldDelegate.lanes, lanes);
}

/// 默认滚动时长（旧常量，保留给调用方做「标准档」参照）。
const Duration kDanmakuDefaultScroll = Duration(milliseconds: _scrollMs);
