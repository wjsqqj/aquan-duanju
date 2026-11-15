import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../models/models.dart';
import '../common.dart';
import 'fx_curves.dart';

// =============================================================================
// 随便看看堆叠选卡（effect-atlas focus-cascade 移植 · E6）
//
// 交互口径：当前卡居中，两侧卡 15° 散开退后（至多各 2 张可见）；拖拽跟手
// （拖一个卡宽 ≈ 翻一张卡）、点侧卡切换（0.7s 归位，[Fx.dockIn] 曲线）、
// 点当前卡确认。无限循环取模（环上 ±2 张副本即「loopCopies」手法）。
//
// 入口分流在调用方：TV 不加入口（焦点导航下拖拽选卡不友好），面板宿主
// 负责空态（AppEmptyState 家族）。reduceMotion：切卡直跳终态（时长归零）。
// =============================================================================

/// 切卡归位时长（atlas focus-cascade 卡片归位窗，[Fx.dockIn] 同源曲线）。
/// kit 级 dartdoc 常量，挂 DESIGN.md §6 编排豁免，不另占五档。
const Duration fxCascadeDock = Duration(milliseconds: 700);

/// 侧卡散开角（15°，atlas 规格）。
final double _kSideAngle = math.pi * 15 / 180;

/// 侧卡水平散距（相对卡宽的比例；±1 卡 30%，更远的每张再退 12%）。
const double _kSideSpread = 0.30;
const double _kSideSpreadFar = 0.12;

/// 纵深参数：每远一张缩 7%、暗 28%。
const double _kDepthScale = 0.07;
const double _kDepthAlpha = 0.28;

/// 可见副本半径（当前卡两侧至多各 2 张）。
const double _kVisibleRadius = 2.5;

/// 甩动判定速度（px/s）。
const double _kFlingVelocity = 400;

/// 堆叠选卡面板（E6）。
///
/// [items] 传当前 tab 抽出的候选（调用方截 12 张以内）；无限循环——
/// 滑过最后一张回到第一张，两个方向都成立。[onPick] 在点**当前卡**时
/// 回调（确认语义）；点侧卡只是切换。
class FxCascadePick extends StatefulWidget {
  const FxCascadePick({super.key, required this.items, required this.onPick});

  final List<SeriesSummary> items;

  /// 点当前卡确认。
  final ValueChanged<SeriesSummary> onPick;

  @override
  State<FxCascadePick> createState() => _FxCascadePickState();
}

class _FxCascadePickState extends State<FxCascadePick>
    with SingleTickerProviderStateMixin {
  /// 浮点卡索引：整数 = 停在某张卡上，小数 = 拖拽中的连续位置。
  double _offset = 0;

  late final AnimationController _settle = AnimationController(vsync: this);

  /// reduceMotion 门控后的归位时长（0 = 直跳终态）。
  Duration _settleDur = fxCascadeDock;
  bool _wired = false;
  bool _settling = false;
  double _from = 0;
  double _to = 0;

  /// 最近一次布局的卡宽（拖拽跟手的灵敏度单位）。
  double _cardWidth = 0;

  int get _n => widget.items.length;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    _settleDur = AppMetrics.reduceMotionOf(context, fxCascadeDock);
    _settle.duration = _settleDur;
    _settle.addListener(_onSettleTick);
    _settle.addStatusListener(_onSettleStatus);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// 把索引归一进 [0, n)（只在整卡落定时做；视觉槽位本来就按模算）。
  double _normalize(double v) {
    final int n = _n;
    if (n <= 0) return 0;
    final double m = v % n;
    return m < 0 ? m + n : m;
  }

  /// 环上相对槽位：把 `i - offset` 折进 [-n/2, n/2)。
  double _relOf(int i) {
    final int n = _n;
    if (n <= 0) return 0;
    final double m = (i - _offset) % n;
    final double v = m < 0 ? m + n : m;
    return v > n / 2 ? v - n : v;
  }

  void _onSettleTick() {
    if (!mounted) return;
    setState(() {
      _offset = _lerp(_from, _to, Fx.dockIn.transform(_settle.value));
    });
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _offset = _normalize(_to);
      _settling = false;
    });
  }

  /// 归位到整卡（点侧卡 / 拖拽松手 / reduceMotion 直跳共用这一口）。
  void _animateTo(double target) {
    final double to = target.roundToDouble();
    if (_n <= 1 ||
        (to - _offset).abs() < 0.001 ||
        _settleDur == Duration.zero) {
      _settle.stop();
      setState(() {
        _settling = false;
        _offset = _normalize(to);
      });
      return;
    }
    setState(() {
      _settling = true;
      _from = _offset;
      _to = to;
    });
    _settle.forward(from: 0);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_n <= 1) return;
    setState(() {
      // 拖动打断归位动画，从当前位置续跟手。
      if (_settling) {
        _settling = false;
        _settle.stop();
      }
      // 向左拖 = 翻下一张（offset 增）；拖一个卡宽 ≈ 翻一张。
      _offset -= details.delta.dx / math.max(1.0, _cardWidth * 0.8);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_n <= 1) return;
    final double vx = details.velocity.pixelsPerSecond.dx;
    // 甩动：至少翻到甩动方向的下一张整卡（ViewPager snap 语义——
    // 半途松手顺甩不回吞），否则就近落卡。
    final int target = vx <= -_kFlingVelocity
        ? _offset.floor() + 1
        : vx >= _kFlingVelocity
        ? _offset.ceil() - 1
        : _offset.round();
    _animateTo(target.toDouble());
  }

  void _onCardTap(int index) {
    if (index < 0 || index >= _n) return;
    final double rel = _relOf(index);
    if (rel.abs() < 0.5) {
      // 当前卡 = 确认。
      widget.onPick(widget.items[index]);
      return;
    }
    _animateTo(_offset + rel);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    if (_n == 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final double cardW = math.min(constraints.maxWidth * 0.62, 380);
        final double cardH = cardW / 1.6;
        _cardWidth = cardW;

        // 环上可见卡（|rel| ≤ 2.5），按 |rel| 从远到近排——近卡后画在上层。
        final List<(int, double)> visible = <(int, double)>[
          for (var i = 0; i < _n; i++)
            if ((_relOf(i)).abs() <= _kVisibleRadius) (i, _relOf(i)),
        ]..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: SizedBox.fromSize(
            size: Size(constraints.maxWidth, cardH),
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (final (int index, double rel) in visible)
                  _buildCard(
                    context,
                    index: index,
                    rel: rel,
                    cardWidth: cardW,
                    cardHeight: cardH,
                    tokens: tokens,
                    m: m,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required int index,
    required double rel,
    required double cardWidth,
    required double cardHeight,
    required AppTokens tokens,
    required AppMetrics m,
  }) {
    final double depth = rel.abs();
    final double angle = rel.sign * _kSideAngle * math.min(depth, 1.0);
    final double dx =
        rel.sign *
        cardWidth *
        (_kSideSpread * math.min(depth, 1.0) +
            (depth > 1 ? _kSideSpreadFar * (depth - 1) : 0));
    final double scale = 1 - _kDepthScale * math.min(depth, 2.0);
    final double alpha = math.max(0.3, 1 - _kDepthAlpha * depth);
    final SeriesSummary item = widget.items[index];
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translateByDouble(dx, 0.0, 0.0, 1.0)
        ..rotateZ(angle)
        ..scaleByDouble(scale, scale, 1.0, 1.0),
      child: Opacity(
        opacity: alpha,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _onCardTap(index),
          child: SizedBox.fromSize(
            size: Size(cardWidth, cardHeight),
            child: ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(m.radiusMd)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage(url: item.coverUrl),
                  // 底部剧名条：surface3 不透明底（不糊玻璃、不加渐变）。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ColoredBox(
                      color: tokens.colors.surface3,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, m.s8),
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.title.copyWith(
                            color: tokens.colors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _settle
      ..removeListener(_onSettleTick)
      ..removeStatusListener(_onSettleStatus)
      ..dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/cascade_pick_test.dart）----

  @visibleForTesting
  double get debugOffset => _offset;

  @visibleForTesting
  bool get debugSettling => _settling;

  @visibleForTesting
  Duration? get debugSettleDuration => _settle.duration;
}
