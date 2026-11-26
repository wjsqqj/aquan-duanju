import 'dart:math' as math;
import 'dart:ui' as ui;

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

  /// 显示行数（弹幕只占画面上方这些行）。1–9。
  ///
  /// 区域高度完全由行数推导：不再有独立的「显示区域」设置。
  final int rows;

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

  /// 显示时钟：每帧按 vsync 增量前进，**不节流**。
  ///
  /// 60Hz 屏每 16.7ms 走一步、120Hz 屏每 8.3ms 走一步；30fps 定时写时钟会让
  /// 弹幕每 2–4 帧才挪一次，肉眼就是「飘过去有停顿」。
  Duration _display = Duration.zero;

  /// 显示位置与播放器位置的误差（measured - display）。
  ///
  /// 误差**不直接改显示位置**（那样是瞬移），而是作为限速补偿的依据：
  /// 每帧把误差按 ≤[kDanmakuDriftRate] 的速度吃掉，速度变化连续且温和。
  Duration _error = Duration.zero;

  /// 上一帧 Ticker 时刻（每帧都更新）。
  Duration _lastTick = Duration.zero;

  /// 当前弹幕时钟（测试断言用）。
  @visibleForTesting
  Duration get debugClock => _clock.value;

  /// 当前未消化的位置误差（测试断言用）。
  @visibleForTesting
  Duration get debugError => _error;

  /// 文字位图缓存（测试断言命中/退化用）。
  @visibleForTesting
  DanmakuGlyphStore get debugGlyphs => _glyphs;

  /// 当前轨道分配器（测试断言有效行数用）。
  @visibleForTesting
  DanmakuLaneAllocator get debugLanes => _lanes;

  /// 文字位图缓存（含描边；每帧只做纹理合成，不重排文字）。
  final DanmakuGlyphStore _glyphs = DanmakuGlyphStore();

  late DanmakuLaneAllocator _lanes = DanmakuLaneAllocator(rows: widget.rows);
  late TextStyle _textStyle = _buildTextStyle();

  /// 描边样式（fill + stroke 两次绘制后烘进位图）；关闭描边时为 null。
  late TextStyle? _strokeStyle = _buildStrokeStyle();

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
    _display = widget.position;
    _clock.value = _display;
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
      _strokeStyle = _buildStrokeStyle();
      _DanmakuPainter.invalidateStyleCache();
      // 位图里连描边一起烘死了：样式一变必须整表作废。
      _glyphs.invalidate();
    }
    if (old.resetEpoch != widget.resetEpoch) {
      // 显式 seek / 换集：允许时间轴回退到播放器位置。
      _resetTo(widget.position);
    } else if (old.position != widget.position) {
      _absorb(widget.position);
    }
    if (old.animating != widget.animating) {
      if (widget.animating) {
        // 恢复播放：以播放器位置重新起算（暂停期间 Ticker 仍在跑，
        // elapsed 已前进，不能沿用旧基准）。
        _display = widget.position;
        _error = Duration.zero;
        _clock.value = _display;
      } else {
        // 进入暂停：冻结在当前显示位置。
        _display = _clock.value;
        _error = Duration.zero;
      }
      _syncTicker();
    } else if (old.enabled != widget.enabled ||
        old.items.length != widget.items.length) {
      _syncTicker();
    }
  }

  /// 填充样式：只负责文字本体，描边由 [_buildStrokeStyle] 单独一层画。
  TextStyle _buildTextStyle() => TextStyle(
        color: PlayerOverlayTokens.textPrimary
            .withValues(alpha: widget.opacity.clamp(0.0, 1.0)),
        fontSize: widget.textSize,
      );

  /// 描边样式：`foreground` + `PaintingStyle.stroke` 的段落。
  ///
  /// 参考 `canvas_danmaku`（Kazumi 在用）与 `NipaPlay`：stroke 段落沿字形轮廓
  /// 均匀加粗，不像 4 向 Shadow 那样在对角留缺口；两次绘制在烘焙位图时只做
  /// 一次，运行期仍是单张纹理。
  TextStyle? _buildStrokeStyle() {
    if (!widget.stroke) return null;
    // 与参考实现同量纲：16px 字号约 1px，字号越大略加粗（上限 2.6px）。
    final double width = (widget.textSize * 0.06).clamp(1.0, 2.6);
    return TextStyle(
      fontSize: widget.textSize,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = PlayerOverlayTokens.hudFill,
    );
  }

  /// Ticker 只由「开关打开 + 有弹幕可画 + 已挂载」决定，**不再依赖 animating**。
  ///
  /// 引擎的播放态会短暂抖动（缓冲、切轨、连播间隙），一抖就停表的话时钟不再
  /// 前进，屏上的弹幕会陆续过期消失——这正是「弹幕先少后没」的成因。
  /// 暂停时不推进时钟（画面冻结），但 Ticker 继续跑，代价是每帧一次同值写入
  /// （ValueNotifier 同值不通知，不触发重绘）。
  void _syncTicker() {
    final need = widget.enabled && widget.items.isNotEmpty && mounted;
    if (need && !_ticker.isActive) {
      // Ticker 重开后 elapsed 归零：时钟换到播放器当前值，避免跳回旧位置。
      _display = widget.position;
      _error = Duration.zero;
      _lastTick = Duration.zero;
      _clock.value = _display;
      _ticker.start();
    } else if (!need && _ticker.isActive) {
      _ticker.stop();
    }
  }

  /// 每个 vsync 推进一次显示时钟（无 30fps 节流）。
  ///
  /// [kDanmakuDriftIgnore] 以上的位置误差不直接改显示位置，而是折算成
  /// ≤[kDanmakuDriftRate] 的速度补偿逐帧吃掉：速度连续变化、时间轴单调。
  void _onTick(Duration elapsed) {
    final Duration delta = elapsed - _lastTick;
    _lastTick = elapsed;
    if (!widget.animating) {
      // 暂停：冻结在当前位置，不写时钟（同值也不会通知）。
      return;
    }
    if (delta <= Duration.zero) return;
    final double rate = widget.rate <= 0 ? 1.0 : widget.rate;
    double factor = 1.0;
    final int errUs = _error.inMicroseconds;
    if (errUs != 0 && errUs.abs() > kDanmakuDriftIgnore.inMicroseconds) {
      final double proportional =
          errUs / kDanmakuDriftWindow.inMicroseconds;
      factor =
          1.0 + proportional.clamp(-kDanmakuDriftRate, kDanmakuDriftRate);
    }
    final int advanced = (delta.inMicroseconds * rate * factor).round();
    _display += Duration(microseconds: advanced);
    if (errUs != 0) {
      // 只有「补偿出来的那部分位移」在消误差；正常推进不改变误差。
      final int compensation =
          (delta.inMicroseconds * rate * (factor - 1)).round();
      final int next = errUs - compensation;
      _error = next.abs() <= kDanmakuDriftIgnore.inMicroseconds
          ? Duration.zero
          : Duration(microseconds: next);
    }
    _clock.value = _display;
  }

  /// 显式重置：seek / 换集 / 换线时把时间轴直接放到播放器位置（允许回退）。
  void _resetTo(Duration position) {
    _display = position;
    _error = Duration.zero;
    _clock.value = position;
  }

  /// 播放器给了新位置：只记录误差，**不直接改显示位置**。
  ///
  /// 显示位置由 [_onTick] 以限速补偿追过去，因此低频位置事件不会让弹幕
  /// 瞬跳或速度突变（旧实现 250ms 内吃掉误差，速度会突然变几十个百分点）。
  void _absorb(Duration measured) {
    if (!widget.animating) {
      // 暂停：只对齐基准，画面保持冻结。
      _display = measured;
      _error = Duration.zero;
      return;
    }
    final Duration err = measured - _display;
    final int abs = err.inMicroseconds.abs();
    if (abs > danmakuHardSeek.inMicroseconds) {
      // 位置事件回退（缓冲、切轨、事件乱序）不是 seek：保持时间轴单调，
      // 否则已经飘出屏幕的弹幕会被拉回来「闪现」。真正的 seek 由
      // resetEpoch 显式通知，不走这里。
      if (err.isNegative) return;
      _display = measured;
      _error = Duration.zero;
      _clock.value = measured;
      return;
    }
    if (abs > kDanmakuSnapError.inMicroseconds) {
      // 中大幅超前/落后：再拖下去观众能看出弹幕与画面不同步，跳一下更划算。
      // 回退仍然一律忽略（缓冲重播不能让弹幕闪回镜头）。
      if (err.isNegative) return;
      _display = measured;
      _error = Duration.zero;
      _clock.value = measured;
      return;
    }
    _error = err;
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
    _glyphs.invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final List<DanmakuRenderItem> display = _visibleItems();
    if (display.isEmpty) return const SizedBox.shrink();
    // 设置里的时长是「1280 宽窗口」基准：宽屏按像素速度校准，避免窗口越宽越快。
    final int scrollMs = effectiveDanmakuScrollMs(
      widget.scrollDuration.inMilliseconds,
      MediaQuery.sizeOf(context).width,
    );
    // 位图要按设备像素比烘：低 DPI 烘高 DPI 画会糊，反之白烧显存。
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    if (dpr != _glyphs.pixelRatio) {
      _glyphs.pixelRatio = dpr;
      _glyphs.invalidate();
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 显示区域完全由行数推导（已移除独立区域设置）：
            // 行数所需高度 = rows × 行高 + 顶部留白；画面太小时按画面高度兜底。
            final double height = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 0.0;
            final double trackHeight = widget.textSize * 1.6;
            final int visibleRows = height > 0
                ? math.max(
                    1,
                    math.min(
                      widget.rows,
                      math.max(
                        1,
                        ((height - kDanmakuTopPad) / trackHeight).floor(),
                      ),
                    ),
                  )
                : math.max(1, widget.rows);
            // 分配器必须与绘制用同一个有效行数，否则弹幕被分散到「画不到的
            // 轨道」上，前几行就会间隔不足、叠在一起。
            if (_lanes.rows != visibleRows) {
              _lanes = DanmakuLaneAllocator(rows: visibleRows);
            }
            return CustomPaint(
              size: Size.infinite,
              painter: _DanmakuPainter(
                frame: _frameFor(display, scrollMs),
                clock: _clock,
                textStyle: _textStyle,
                strokeStyle: _strokeStyle,
                rows: visibleRows,
                lanes: _lanes,
                glyphs: _glyphs,
                pixelRatio: dpr,
              ),
            );
          },
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

/// 位置误差小于它视为噪声：肉眼不可见，不做速度补偿。
const Duration kDanmakuDriftIgnore = Duration(milliseconds: 32);

/// 速度补偿的比例窗口：误差等于它时速度偏差达到 [kDanmakuDriftRate]。
const Duration kDanmakuDriftWindow = Duration(milliseconds: 400);

/// 速度补偿上限：显示速度相对基准倍速最多相差 6%（每秒最多追 6% 的时间）。
///
/// 6% 的速度差异肉眼几乎不可见，但它保证了「每来一次位置事件就变速几十
/// 个百分点」的顿挫彻底消失。
const double kDanmakuDriftRate = 0.06;

/// 误差超过它直接对齐显示时钟（跳一下），避免长时间与画面错位。
const Duration kDanmakuSnapError = Duration(milliseconds: 500);

/// 弹幕层顶部留白（逻辑像素）：State 与 Painter 共用同一个值。
const double kDanmakuTopPad = 8;

/// 单帧最多新烘几张文字位图：极端密集/seek 后首帧不把主线程堵死，
/// 超出的条目本帧退回 TextPainter 直接画。
const int kDanmakuGlyphBuildPerFrame = 6;

/// 同屏最多绘制条数：异常数据（单秒几百条）不许把一帧的绘制时间拉爆。
const int kDanmakuMaxConcurrent = 120;

/// 把设置里的「基准滚动时长」换算成当前窗口宽度下的实际时长。
///
/// 固定时长在宽窗口上意味着更快的像素速度：8s 在 1280 宽约 179px/s，
/// 1920 宽约 259px/s、2560 宽约 339px/s —— 这是「标准档仍偏快」的根因。
/// 参考 `canvas_danmaku`（默认 10s）与 `hongguoTV`（11s）在 1920 宽约
/// 200–210px/s，这里按 `width / 1500` 放大时长（封顶 2x），
/// 让 1280–3000 宽窗口的像素速度都落在 ~180–210px/s。
@visibleForTesting
int effectiveDanmakuScrollMs(int baseMs, double viewWidth) {
  final double width =
      viewWidth.isFinite && viewWidth > 0 ? viewWidth : 1500;
  final double scale = (width / 1500).clamp(1.0, 2.0);
  return (baseMs * scale).round().clamp(1000, 24000);
}

/// 弹幕时钟的解析式插值：位置 = 基准 + (tick - 基准时刻) × 倍率。
///
/// 保留为纯函数供测试/外部复用；overlay 内部已改为「显示时钟 + 限速补偿」
/// 模型（见 [_DanmakuOverlayState._onTick]），不再用它逐帧算位置。
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
/// 绘制期（每帧 × 屏上条数）不再做任何字符串拼接。
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
/// 不再每帧执行（此前是每帧 × 全量过滤）。
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

/// 用**微秒时钟**算弹幕的 X 坐标。
///
/// 手机 120Hz 的帧间隔是 8.33ms，若用 `Duration.inMilliseconds` 会得到
/// 8/8/9/8...ms 的交替序列，X 每帧在两根之间跳，物理像素放大 2–3x 后
/// 肉眼就是「左右轻微跳动」。这里保留亚毫秒精度，让每帧位移严格均匀。
///
/// [posUs] 是弹幕时钟的微秒值；[progressMs] 是该条弹幕的出现时间（毫秒）。
double danmakuXAt({
  required int posUs,
  required int progressMs,
  required int scrollMs,
  required double viewWidth,
  required double textWidth,
}) {
  final double elapsedMs = posUs / 1000.0 - progressMs;
  final double progress = elapsedMs / scrollMs;
  return viewWidth - progress * (viewWidth + textWidth);
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
    required this.strokeStyle,
    required this.rows,
    required this.lanes,
    required this.glyphs,
    required this.pixelRatio,
  }) : super(repaint: clock);

  /// 帧快照（排序 + 二分索引），由 State 缓存，绘制期只读。
  final DanmakuFrame frame;

  /// 弹幕时钟：painter 直接订阅它，每帧只重绘，不重建 widget。
  final ValueListenable<Duration> clock;
  final TextStyle textStyle;

  /// 描边样式（可为 null = 关闭描边）。
  final TextStyle? strokeStyle;

  /// 有效显示行数（由 State 根据行数设置与画面高度推导）。
  final int rows;

  /// 固定轨道分配器（State 持有，跨帧稳定）。
  final DanmakuLaneAllocator lanes;

  /// 文字位图缓存（含描边）。每帧只做 drawImageRect，不再重排/重画文字。
  final DanmakuGlyphStore glyphs;

  /// 烘位图用的设备像素比（清晰度靠它）。
  final double pixelRatio;

  static final Map<String, TextPainter> _painters = <String, TextPainter>{};
  static final Map<String, TextPainter> _strokePainters =
      <String, TextPainter>{};
  static int? _styleHash;

  /// 文本排版缓存上限：超限按插入顺序淘汰最早 25%，**不再整表清空**。
  /// 旧实现 `if (length > 300) clear()` 会让密集段反复全量重新 layout。
  static const int _painterCacheMax = 1200;

  /// 样式变化时由 State 调用：旧样式的排版结果必须作废。
  static void invalidateStyleCache() {
    _painters.clear();
    _strokePainters.clear();
    _styleHash = null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 位置必须保留亚毫秒精度：120Hz 手机上 inMilliseconds 的 8/9ms 交替
    // 会让弹幕每帧左右跳一格（物理像素放大后非常明显）。
    final int posUs = clock.value.inMicroseconds;
    final int posMs = (posUs / 1000).round(); // 仅用于秒级二分窗口，误差可忽略
    final int scrollMs = frame.scrollMs;
    final double trackHeight = _trackHeight;
    // 行数已由 State 按画面高度收敛；这里只按真实高度再兜一次底，
    // 保证小窗不会把弹幕画到画面外。
    final int visibleRows = math.max(
      1,
      math.min(rows, math.max(1, ((size.height - _topPad) / trackHeight).floor())),
    );
    // 二分出 [pos - scrollMs, pos] 的窗口：绘制成本只与屏上条数相关，
    // 与本集总条数无关（旧实现在 8000 条的集上每帧全表扫描）。
    final ({int start, int end}) window =
        danmakuWindow(frame.starts, posMs, scrollMs);
    if (window.start >= window.end) return;

    // strokeStyle 里的 Paint 不参与 TextStyle 的相等比较，样式哈希只看填充样式
    // 就够：描边开关/字号变化时 State 已调用 invalidateStyleCache()。
    final int styleHash = textStyle.hashCode;
    if (_styleHash != styleHash) {
      _painters.clear();
      _strokePainters.clear();
      _styleHash = styleHash;
    }

    // 只在本层显示区内绘制（显示区高度 = 有效行数 × 行高 + 顶部留白），
    // 不裁剪会让描边与文字在整屏 overdraw。
    final Rect clip = Rect.fromLTWH(
      0,
      0,
      size.width,
      math.min(size.height, _topPad + visibleRows * trackHeight),
    );
    canvas.save();
    canvas.clipRect(clip);

    final List<DanmakuRenderItem> items = frame.items;
    int drawn = 0;
    int built = 0;
    for (var i = window.start; i < window.end; i++) {
      if (drawn >= kDanmakuMaxConcurrent) break;
      final DanmakuRenderItem item = items[i];
      final double deltaMs = posUs / 1000.0 - item.progressMs;
      if (deltaMs < 0 || deltaMs > scrollMs) continue;
      final TextPainter painter = _painterFor(item.text);
      if (painter.width <= 0) continue;
      final TextPainter? strokePainter = _strokePainterFor(item.text);
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
      final double x = danmakuXAt(
        posUs: posUs,
        progressMs: item.progressMs,
        scrollMs: scrollMs,
        viewWidth: size.width,
        textWidth: painter.width,
      );
      if (x + painter.width < 0) continue;
      final double y = _topPad + lane * trackHeight;
      drawn++;
      // 文字 + 描边只在首次出现时烘成一张位图，之后每帧 drawImageRect：
      // 主线程不再重复排版/绘制 5 遍 paragraph（密集段的主要开销）。
      DanmakuGlyph? glyph = glyphs.lookup(item.text);
      if (glyph == null && built < kDanmakuGlyphBuildPerFrame) {
        built++;
        glyph = glyphs.build(item.text, painter, strokePainter, pixelRatio);
      }
      if (glyph != null) {
        glyph.paint(canvas, Offset(x, y));
      } else {
        // 本帧限额用尽 / Emoji / 位图不可用：直接画，绝不出现空白。
        strokePainter?.paint(canvas, Offset(x, y));
        painter.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
  }

  /// 顶部留白：弹幕不贴画面边缘（与 State 的有效行数计算共用）。
  static const double _topPad = kDanmakuTopPad;

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

  /// 描边段落（与填充段落同文本/字号，仅 foreground 是 stroke Paint）。
  TextPainter? _strokePainterFor(String text) {
    final TextStyle? style = strokeStyle;
    if (style == null) return null;
    final TextPainter? cached = _strokePainters[text];
    if (cached != null) return cached;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    if (_strokePainters.length >= _painterCacheMax) {
      final int drop = (_painterCacheMax ~/ 4) + 1;
      final List<String> victims =
          _strokePainters.keys.take(drop).toList(growable: false);
      for (final String key in victims) {
        _strokePainters.remove(key);
      }
    }
    _strokePainters[text] = tp;
    return tp;
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) =>
      !identical(oldDelegate.frame, frame) ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.strokeStyle != strokeStyle ||
      oldDelegate.rows != rows ||
      oldDelegate.pixelRatio != pixelRatio ||
      !identical(oldDelegate.lanes, lanes) ||
      !identical(oldDelegate.glyphs, glyphs);
}

/// 单条弹幕的预渲染位图：文字 + 描边一起烘死，绘制期只做纹理合成。
///
/// 参考 `guoappxxx` / `THLRedGuo` 的 `RepaintBoundary(Text) + Transform`：
/// 文字只栅格化一次，之后每帧只移动合成层。CustomPaint 内用位图达到同样的
/// 成本模型，同时保留二分窗口与轨道分配管线。
class DanmakuGlyph {
  DanmakuGlyph(
    this.image,
    this.logicalWidth,
    this.logicalHeight,
    this.bakeRatio,
  );

  final ui.Image image;

  /// 逻辑尺寸（含两侧 [pad]）。
  final double logicalWidth;
  final double logicalHeight;

  /// 烘焙倍率（设备像素比 × 超采样）：绘制时按它把位图还原到逻辑尺寸。
  final double bakeRatio;

  /// 描边/抗锯齿余量（逻辑像素）。
  static const double pad = 2;

  /// 双线性：按亚像素位置采样，避免最近邻的 1px 跳格/丢列（移动发虚的根因）。
  /// 位图本身按 2x 超采样烘焙，下采样后仍保持锐度。
  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  void paint(Canvas canvas, Offset offset) {
    // 用位图真实像素数还原（image.width / bakeRatio），不再按 logicalWidth 画：
    // logicalWidth 与 ceil(logicalWidth*bakeRatio)/bakeRatio 差 <1px，会造成
    // 每帧亚像素缩放，最近邻采样时表现为丢列/跳列 → 移动中的文字发虚。
    final double dstW = image.width / bakeRatio;
    final double dstH = image.height / bakeRatio;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(offset.dx - pad, offset.dy - pad, dstW, dstH),
      _paint,
    );
  }

  void dispose() => image.dispose();
}

/// 文字位图缓存（键 = 展示文本，值 = 含描边的位图）。
///
/// 样式（字号/透明度/描边）或 DPR 变化时必须由调用方 [invalidate]：
/// 位图里连描边一起烘死了，样式一变整表作废。缓存有上限，长视频内存恒定。
class DanmakuGlyphStore {
  DanmakuGlyphStore({
    this.maxEntries = 400,
    this.maxPixels = 12 * 1024 * 1024,
  });

  /// 条数上限。
  final int maxEntries;

  /// 像素总量上限（设备像素，约 48MB RGBA）：长弹幕/高 DPI 下按条数算不够。
  final int maxPixels;

  /// 设备像素比：位图按它烘，避免高 DPI 模糊。
  double pixelRatio = 1.0;

  final Map<String, DanmakuGlyph> _glyphs = <String, DanmakuGlyph>{};
  int _pixels = 0;
  int _builds = 0;
  bool _disabled = false;

  /// 累计烘图次数（测试断言缓存命中用）。
  @visibleForTesting
  int get debugBuilds => _builds;

  @visibleForTesting
  int get debugLength => _glyphs.length;

  /// true = 平台不支持 [ui.Picture.toImageSync]，已退化为逐帧 TextPainter。
  @visibleForTesting
  bool get debugDisabled => _disabled;

  DanmakuGlyph? lookup(String text) => _glyphs[text];

  /// 烘一张位图。失败时永久退化（返回 null，调用方直画），不允许整层空白。
  ///
  /// [strokePainter] 为描边段落（可为 null）：先描边后填充，一起烘进同一张图。
  DanmakuGlyph? build(
    String text,
    TextPainter painter,
    TextPainter? strokePainter,
    double ratio,
  ) {
    if (_disabled) return null;
    final DanmakuGlyph? cached = _glyphs[text];
    if (cached != null) return cached;
    // Impeller 的 toImageSync 不支持彩色 Emoji（CBDT/COLRv1）离屏光栅化，
    // 硬烘会得到一张空图。含 Emoji 的弹幕直接走 TextPainter 直画。
    if (_hasColorEmoji(text)) return null;
    final double dpr = ratio.isFinite && ratio > 0 ? ratio : 1.0;
    // 2x 超采样（设备 DPR 已很高时封顶 3x）：SSAA + 双线性下采样，
    // 移动中按亚像素采样仍然锐利；1x 直接采样在高对比文字上会显毛边/发虚。
    final double bakeRatio = (dpr * 2).clamp(dpr, 3.0);
    final double logicalW =
        math.max(painter.width, strokePainter?.width ?? 0) +
            DanmakuGlyph.pad * 2;
    final double logicalH =
        math.max(painter.height, strokePainter?.height ?? 0) +
            DanmakuGlyph.pad * 2;
    final int pixelW = (logicalW * bakeRatio).ceil();
    final int pixelH = (logicalH * bakeRatio).ceil();
    // 单张超纹理上限（罕见超长弹幕）：不烘，逐帧直画（成本可控且不占显存）。
    if (pixelW > 4096 || pixelH > 2048 || pixelW <= 0 || pixelH <= 0) {
      return null;
    }
    try {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas recorderCanvas = Canvas(recorder);
      recorderCanvas.scale(bakeRatio);
      // Impeller 下 toImageSync 的纹理可能未初始化：先明确清成透明。
      recorderCanvas.drawRect(
        Rect.fromLTWH(0, 0, logicalW, logicalH),
        Paint()..blendMode = BlendMode.clear,
      );
      const Offset origin = Offset(DanmakuGlyph.pad, DanmakuGlyph.pad);
      strokePainter?.paint(recorderCanvas, origin);
      painter.paint(recorderCanvas, origin);
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = picture.toImageSync(pixelW, pixelH);
      picture.dispose();
      _evictIfNeeded(pixelW * pixelH);
      final DanmakuGlyph glyph =
          DanmakuGlyph(image, logicalW, logicalH, bakeRatio);
      _glyphs[text] = glyph;
      _pixels += pixelW * pixelH;
      _builds++;
      return glyph;
    } catch (_) {
      // 不支持 toImageSync / 显存不足：退化为逐帧 TextPainter 绘制。
      _disabled = true;
      return null;
    }
  }

  /// 是否含彩色 Emoji（含 ZWJ / 变体选择符）：这些字符不能走 toImageSync。
  static bool _hasColorEmoji(String text) {
    for (final int rune in text.runes) {
      if (rune == 0x200D || (rune >= 0xFE00 && rune <= 0xFE0F)) {
        return true;
      }
      if ((rune >= 0x1F000 && rune <= 0x1FAFF) ||
          (rune >= 0x2600 && rune <= 0x27BF) ||
          (rune >= 0x2B00 && rune <= 0x2BFF)) {
        return true;
      }
    }
    return false;
  }

  /// 腾到「加完这一张也不超」为止：按插入顺序淘汰最早 25%（至少一张）。
  void _evictIfNeeded(int incomingPixels) {
    while (_glyphs.isNotEmpty &&
        (_glyphs.length >= maxEntries ||
            _pixels + incomingPixels > maxPixels)) {
      final int want = math.max(1, _glyphs.length ~/ 4);
      final List<String> victims =
          _glyphs.keys.take(want).toList(growable: false);
      for (final String key in victims) {
        final DanmakuGlyph? old = _glyphs.remove(key);
        if (old == null) continue;
        _pixels -= old.image.width * old.image.height;
        old.dispose();
      }
    }
  }

  /// 样式或 DPR 变化：整表作废并释放纹理。
  void invalidate() {
    for (final DanmakuGlyph glyph in _glyphs.values) {
      glyph.dispose();
    }
    _glyphs.clear();
    _pixels = 0;
  }
}

/// 默认滚动时长（旧常量，保留给调用方做「标准档」参照）。
const Duration kDanmakuDefaultScroll = Duration(milliseconds: _scrollMs);
