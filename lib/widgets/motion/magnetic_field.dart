import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerExitEvent, PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';

/// 指针影响半径：230px（atlas magnetic-symbol-field influenceRadius 230）。
/// kit 常量（atlas 出处）。
const double kMagnetInfluenceRadius = 230;

/// 推开位移上限：92px（atlas displacement 92）。
const double kMagnetDisplacement = 92;

/// 衰减指数：1.6（atlas falloff 1.6——位移随距离 (1-d/r)^1.6）。
const double kMagnetFalloff = 1.6;

/// 弹簧刚度按 5 组递增：k = 150..238（atlas k=150..238）。
const double kMagnetStiffnessBase = 150;
const double kMagnetStiffnessStep = 22;

/// 阻尼（atlas c = 15 + (i%3)*2.2——邻居错拍「涟漪」的来源之一）。
const double kMagnetDampingBase = 15;
const double kMagnetDampingStep = 2.2;

/// 倾斜系数：水平速度 × 0.025°（atlas 同值）。
const double kMagnetTiltDegPerPx = 0.025;

/// 物理步长上限：34ms（atlas dt 上限；卡顿跳帧不放大积分步）。
const int kMagnetMaxStepMs = 34;

/// snap 阈值：距目标 <0.05px 且速度 <0.5px/s（atlas 同值）——全卡满足即
/// 停表（静止零开销）。
const double kMagnetSnapDistance = 0.05;
const double kMagnetSnapSpeed = 0.5;

/// home 点分数坐标表（atlas magnetic-symbol-field WIDE/TALL 表降编）：
/// 宽屏 11 张 / 窄屏 7 张，避开中央（空态内容居中，磁力卡只在四周）。
const List<Offset> kMagnetHomesWide = <Offset>[
  Offset(0.07, 0.14),
  Offset(0.24, 0.08),
  Offset(0.45, 0.16),
  Offset(0.68, 0.08),
  Offset(0.90, 0.18),
  Offset(0.10, 0.44),
  Offset(0.91, 0.50),
  Offset(0.13, 0.76),
  Offset(0.38, 0.90),
  Offset(0.63, 0.82),
  Offset(0.88, 0.80),
];

const List<Offset> kMagnetHomesNarrow = <Offset>[
  Offset(0.09, 0.12),
  Offset(0.36, 0.08),
  Offset(0.70, 0.14),
  Offset(0.93, 0.38),
  Offset(0.07, 0.52),
  Offset(0.30, 0.90),
  Offset(0.72, 0.86),
];

/// 宽窄屏分界（分数坐标表切换点）。
const double kMagnetWideBreakpoint = 600;

/// 卡片尺寸序列：24..40px（atlas 卡 24-40 圆角小卡）。
double magnetCardSize(int index) => 24.0 + (index % 5) * 4.0;

enum _SymbolKind { ring, plus, square, cross }

/// 空态背景磁力符号场（effect-atlas magnetic-symbol-field 移植 · E5）。
///
/// 空态四周散布小符号卡（圆环/加号/方块/叉，Canvas 内绘非 icon 字体），
/// 桌面指针靠近被推开、沿弹簧摆回，逐卡刚度/阻尼递变形成邻居错拍涟漪；
/// 全部落定自动停表（静止零开销）。
///
/// 结构：`Stack[指针捕捉层, 磁力卡层(IgnorePointer), child]`——磁力卡是
/// **纯装饰层**，整层 IgnorePointer，不抢空态的点击/重试手势；指针捕捉
/// 层垫底，只在空态内容未命中的空白处认领 hover（内容区的按钮/手势不受
/// 影响）。
///
/// 门控：**桌面 only**（`Theme.platform`，移动/TV 不装 MouseRegion、不建
/// 卡片、不起 Ticker，零开销）；「减少动效」静态直出（卡片摆在 home 位，
/// 无物理）。
class FxMagneticField extends StatefulWidget {
  const FxMagneticField({super.key, required this.child});

  /// 空态内容（前景，磁力卡是它的背景层）。
  final Widget child;

  @override
  State<FxMagneticField> createState() => _FxMagneticFieldState();
}

class _FxMagneticFieldState extends State<FxMagneticField>
    with SingleTickerProviderStateMixin {
  /// 直出形态：移动/TV（不建卡、不装 MouseRegion、不起 Ticker）。
  bool _physics = false;

  /// 静态形态：桌面 + reduceMotion（卡片摆在 home 位）。
  bool _staticOnly = false;

  bool _wired = false;

  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;

  /// 指针位置（**像素**，场内局部坐标；null = 已离场，卡片弹回 home）。
  Offset? _pointer;

  /// 卡片状态跨帧保持（数量随宽窄切换才重建）。
  List<_MagnetCard>? _cards;

  /// 渲染侧写入场尺寸（物理目标依赖它；LayoutBuilder 与 Ticker 拍共享）。
  Size? _fieldSize;

  /// 重绘信号（单 Ticker → 全卡统一重绘）。
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    // 桌面判定走 Theme.platform（E1-E3 沉淀：defaultTargetPlatform 不可
    // 注入且测试用 ThemeData(platform:)）。
    final bool desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    if (!desktop) return; // 移动/TV 零开销
    _staticOnly = AppMetrics.reduceMotionEnabled(context);
    _physics = !_staticOnly;
  }

  List<_MagnetCard> _cardsFor(double width) {
    final bool wide = width >= kMagnetWideBreakpoint;
    final int count = wide
        ? kMagnetHomesWide.length
        : kMagnetHomesNarrow.length;
    final List<_MagnetCard>? existing = _cards;
    if (existing != null && existing.length == count) return existing;
    final List<Offset> homes = wide ? kMagnetHomesWide : kMagnetHomesNarrow;
    return _cards = <_MagnetCard>[
      for (int i = 0; i < homes.length; i++) _MagnetCard(homes[i], i),
    ];
  }

  void _onHover(PointerHoverEvent event) {
    _pointer = event.localPosition;
    _ensureTicker();
  }

  void _onExit(PointerExitEvent _) {
    _pointer = null;
    _ensureTicker(); // 弹回 home 的收尾拍
  }

  void _ensureTicker() {
    if (!_physics) return;
    _ticker ??= createTicker(_onTick);
    if (!_ticker!.isActive) {
      _lastElapsed = Duration.zero;
      _ticker!.start();
    }
  }

  void _onTick(Duration elapsed) {
    final Duration dt = elapsed == Duration.zero
        ? Duration
              .zero // 起表首拍不推进（与 speed_scramble 同口径）
        : (_lastElapsed == Duration.zero ? elapsed : elapsed - _lastElapsed);
    _lastElapsed = elapsed;
    final double dtS =
        (dt.inMicroseconds / 1000).clamp(0, kMagnetMaxStepMs) / 1000;
    final Offset? pointer = _pointer;
    final Size fieldSize = _fieldSize ?? Size.zero;
    final List<_MagnetCard> cards = _cards ?? const <_MagnetCard>[];
    var allSettled = true;
    for (final card in cards) {
      // 目标位移：影响半径内沿背离指针方向推开 (1-d/r)^falloff，否则 home。
      final Offset target = _targetOf(card, pointer, fieldSize);
      // 半隐式欧拉：先积速度再积位置（k·dt² 远小于稳定界）。
      final double ax = -card.k * (card.x - target.dx) - card.c * card.vx;
      final double ay = -card.k * (card.y - target.dy) - card.c * card.vy;
      card.vx += ax * dtS;
      card.vy += ay * dtS;
      card.x += card.vx * dtS;
      card.y += card.vy * dtS;
      final double gapX = card.x - target.dx;
      final double gapY = card.y - target.dy;
      if (gapX.abs() < kMagnetSnapDistance &&
          gapY.abs() < kMagnetSnapDistance &&
          card.vx.abs() < kMagnetSnapSpeed &&
          card.vy.abs() < kMagnetSnapSpeed) {
        card.x = target.dx;
        card.y = target.dy;
        card.vx = 0;
        card.vy = 0;
      } else {
        allSettled = false;
      }
    }
    if (allSettled) {
      _ticker?.stop(); // 静止停表
    }
    _frame.value++;
  }

  /// 卡片的目标位移（相对 home 的 px）。
  Offset _targetOf(_MagnetCard card, Offset? pointer, Size fieldSize) {
    if (pointer == null || fieldSize == Size.zero) return Offset.zero;
    final Offset home = Offset(
      card.homeFraction.dx * fieldSize.width,
      card.homeFraction.dy * fieldSize.height,
    );
    final Offset delta = home - pointer;
    final double d = delta.distance;
    if (d >= kMagnetInfluenceRadius || d <= 0.0001) return Offset.zero;
    final double strength = math
        .pow(1 - d / kMagnetInfluenceRadius, kMagnetFalloff)
        .toDouble();
    return delta * (kMagnetDisplacement * strength / d);
  }

  @override
  Widget build(BuildContext context) {
    if (!_physics && !_staticOnly) {
      // 移动/TV：直出，零构建。
      return widget.child;
    }
    if (!_physics) {
      return _StaticField(child: widget.child);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        _fieldSize = Size(w, h);
        final List<_MagnetCard> cards = _cardsFor(w);
        return Stack(
          children: <Widget>[
            // 指针捕捉层（垫底）：只在空态内容未命中的空白处认领 hover，
            // 内容区的按钮/重试手势优先（Stack 命中测试自上而下）。
            Positioned.fill(
              child: MouseRegion(
                onHover: _onHover,
                onExit: _onExit,
                child: const SizedBox.expand(),
              ),
            ),
            // 磁力卡层：纯装饰，IgnorePointer 不抢任何手势。
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<int>(
                  valueListenable: _frame,
                  builder: (context, _, _) {
                    return _CardLayer(
                      cards: cards,
                      fieldSize: _fieldSize ?? Size(w, h),
                    );
                  },
                ),
              ),
            ),
            widget.child,
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _frame.dispose();
    super.dispose();
  }

  // ---- 测试口（test/motion/magnetic_field_test.dart）----

  @visibleForTesting
  bool get debugPhysics => _physics;

  @visibleForTesting
  bool get debugStaticOnly => _staticOnly;

  @visibleForTesting
  bool get debugTickerActive => _ticker?.isActive ?? false;

  @visibleForTesting
  int get debugCardCount => _cards?.length ?? 0;

  @visibleForTesting
  Offset debugCardDisplacement(int index) =>
      Offset(_cards![index].x, _cards![index].y);
}

/// 单卡弹簧状态（物理量在**相对 home 的像素位移**空间；home 由分数坐标
/// × 场尺寸在每帧渲染侧算出，resize 只改目标不改弹簧状态）。
class _MagnetCard {
  _MagnetCard(this.homeFraction, this.index)
    : k = kMagnetStiffnessBase + (index % 5) * kMagnetStiffnessStep,
      c = kMagnetDampingBase + (index % 3) * kMagnetDampingStep,
      symbol = _SymbolKind.values[index % _SymbolKind.values.length],
      size = magnetCardSize(index);

  final Offset homeFraction;
  final int index;
  final double k;
  final double c;
  final _SymbolKind symbol;
  final double size;

  double x = 0;
  double y = 0;
  double vx = 0;
  double vy = 0;
}

/// 卡片渲染层（位移画在 Transform 上；倾斜 = 水平速度 × 0.025°）。
class _CardLayer extends StatelessWidget {
  const _CardLayer({required this.cards, required this.fieldSize});

  final List<_MagnetCard> cards;
  final Size fieldSize;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[for (final card in cards) _card(card, tokens)],
    );
  }

  Widget _card(_MagnetCard card, AppTokens tokens) {
    final Offset home = Offset(
      card.homeFraction.dx * fieldSize.width,
      card.homeFraction.dy * fieldSize.height,
    );
    final double tiltRad = card.vx * kMagnetTiltDegPerPx * math.pi / 180;
    return Positioned(
      left: home.dx + card.x - card.size / 2,
      top: home.dy + card.y - card.size / 2,
      child: Transform.rotate(
        angle: tiltRad,
        child: _SymbolCard(card: card, tokens: tokens),
      ),
    );
  }
}

/// 单张符号卡：surface2 底 + hairline 描边 + Canvas 内绘符号（brand 仅加号）。
class _SymbolCard extends StatelessWidget {
  const _SymbolCard({required this.card, required this.tokens});

  final _MagnetCard card;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final Color symbolColor = card.symbol == _SymbolKind.plus
        ? tokens.colors.brand
        : tokens.colors.textTertiary;
    return Container(
      width: card.size,
      height: card.size,
      decoration: BoxDecoration(
        color: tokens.colors.surface2,
        borderRadius: const BorderRadius.all(
          Radius.circular(AppSpacing.radiusSm),
        ),
        border: Border.fromBorderSide(
          BorderSide(
            color: tokens.colors.hairline,
            width: tokens.metrics.hairline,
          ),
        ),
      ),
      child: CustomPaint(
        painter: _SymbolPainter(
          kind: card.symbol,
          color: symbolColor,
          stroke: math.max(1.5, tokens.metrics.hairline + 0.5),
        ),
      ),
    );
  }
}

/// 符号绘制（圆环 / 加号 / 方块 / 叉，内联 Canvas，非 icon 字体）。
class _SymbolPainter extends CustomPainter {
  const _SymbolPainter({
    required this.kind,
    required this.color,
    required this.stroke,
  });

  final _SymbolKind kind;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final Paint pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final double r = size.shortestSide * 0.28;
    switch (kind) {
      case _SymbolKind.ring:
        canvas.drawCircle(center, r, pen);
      case _SymbolKind.plus:
        canvas.drawLine(center - Offset(r, 0), center + Offset(r, 0), pen);
        canvas.drawLine(center - Offset(0, r), center + Offset(0, r), pen);
      case _SymbolKind.square:
        canvas.drawRect(Rect.fromCircle(center: center, radius: r * 0.9), pen);
      case _SymbolKind.cross:
        final Offset d = Offset(r * 0.8, r * 0.8);
        canvas.drawLine(center - d, center + d, pen);
        canvas.drawLine(
          center + Offset(-d.dx, d.dy),
          center + Offset(d.dx, -d.dy),
          pen,
        );
    }
  }

  @override
  bool shouldRepaint(_SymbolPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.color != color ||
      oldDelegate.stroke != stroke;
}

/// 静态场（「减少动效」）：卡片摆在 home 位，无 MouseRegion、无 Ticker。
class _StaticField extends StatelessWidget {
  const _StaticField({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size fieldSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        final bool wide = fieldSize.width >= kMagnetWideBreakpoint;
        final List<Offset> homes = wide ? kMagnetHomesWide : kMagnetHomesNarrow;
        final AppTokens tokens = context.app;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    for (int i = 0; i < homes.length; i++)
                      Positioned(
                        left:
                            homes[i].dx * fieldSize.width -
                            magnetCardSize(i) / 2,
                        top:
                            homes[i].dy * fieldSize.height -
                            magnetCardSize(i) / 2,
                        child: _SymbolCard(
                          card: _MagnetCard(homes[i], i),
                          tokens: tokens,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            child,
          ],
        );
      },
    );
  }
}
