import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// 果冻/半流体的物理手感参数（对应 `design.md §13.3` 三档）。
///
/// 六参数之外不得再加：`edge/bend/shape` 是三重距离约束的刚度，
/// `pressure` 决定「装满了东西」的体积感（半流体的关键），
/// `tether` 决定回位快慢（UI 元素必须锚定，不能像原版游戏那样掉落）。
@immutable
class JellyPhysics {
  const JellyPhysics({
    required this.edge,
    required this.bend,
    required this.shape,
    required this.damping,
    required this.pressure,
    required this.tether,
  });

  /// 弹、脆：按钮 / chip / Tab / 开关。
  static const JellyPhysics snap = JellyPhysics(
    edge: .90,
    bend: .55,
    shape: .055,
    damping: .997,
    pressure: .85,
    tether: .10,
  );

  /// 软、慢：卡片 hover / 拖拽 / 面板展开。
  static const JellyPhysics flow = JellyPhysics(
    edge: .70,
    bend: .24,
    shape: .017,
    damping: .992,
    pressure: .80,
    tether: .06,
  );

  /// 流动感：播放器手势反馈 / Toast。
  static const JellyPhysics melt = JellyPhysics(
    edge: .44,
    bend: .12,
    shape: .007,
    damping: .978,
    pressure: .72,
    tether: .03,
  );

  final double edge;
  final double bend;
  final double shape;
  final double damping;
  final double pressure;
  final double tether;
}

/// 软体环：N 个周向粒子，Verlet 积分 + 三重距离约束 + 面积守恒压力。
///
/// 算法移植自 `astra_games/melon-lab/physics.js`（半流体西瓜）。相对原版有两处
/// 面向 UI 的必要改造（都有实测依据，见 `design.md §13.2`）：
///
/// 1. **零重力 + 回位系绳**：原版靠屏幕边界墙兜住，软体会掉到画面底部；UI 元素
///    必须锚定原位，否则按钮会一路下滑。
/// 2. **约束目标长度从静止多边形实测**：原版粒子均布在圆上，可以直接用
///    `2r·sin(π/n)`；UI 要画胶囊/圆角矩形，用圆的解析式会把 168×56 撑成圆饼。
///
/// 它是 [ChangeNotifier]：每步物理后 `notifyListeners()`，自绘 painter 用
/// `repaint:` 直接订阅即可重绘，**不需要**每帧 `setState` 重建整棵子树。
class SoftRing extends ChangeNotifier {
  SoftRing({required this.center, required this.radius, required this.physics})
    : _points = List<Offset>.filled(pointCount, Offset.zero, growable: false),
      _prev = List<Offset>.filled(pointCount, Offset.zero, growable: false),
      _rest = List<Offset>.filled(pointCount, Offset.zero, growable: false) {
    setCircle(center, radius);
  }

  /// 周向粒子数。18 是原版取值，胶囊/圆角矩形也够平滑。
  static const int pointCount = 18;

  final List<Offset> _points;
  final List<Offset> _prev;

  /// 每个粒子相对中心的静止位置。
  final List<Offset> _rest;

  /// 三重约束的目标长度，由静止多边形实测得出（见 [_measureRest]）。
  final List<double> _edgeLen = List<double>.filled(
    pointCount,
    0,
    growable: false,
  );
  final List<double> _bendLen = List<double>.filled(
    pointCount,
    0,
    growable: false,
  );
  final List<double> _spanLen = List<double>.filled(
    pointCount,
    0,
    growable: false,
  );

  Offset center;
  double radius;
  JellyPhysics physics;

  /// 静止形状面积，压力约束以此为基准。
  double restArea = 1;

  /// 是否已经足够接近静止形状（外壳可据此停掉 ticker 省电）。
  bool get isSettled {
    for (var i = 0; i < pointCount; i++) {
      final d = (_points[i] - (center + _rest[i])).distance;
      if (d > radius * 0.02) return false;
    }
    return true;
  }

  /// 用正圆作为静止形状。
  void setCircle(Offset c, double r) {
    center = c;
    radius = r;
    for (var i = 0; i < pointCount; i++) {
      final a = math.pi * 2 * i / pointCount;
      final p = Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
      _points[i] = p;
      _prev[i] = p;
      _rest[i] = p - c;
    }
    restArea = _area();
    _measureRest();
    notifyListeners();
  }

  /// 用任意闭合多边形作为静止形状（相对中心的偏移量）。
  ///
  /// 按钮请用 [superellipse] 生成胶囊/圆角矩形的偏移量。
  void setPolygon(Offset c, List<Offset> offsets) {
    assert(offsets.length == pointCount, 'offsets 必须恰好 $pointCount 个');
    center = c;
    var sum = 0.0;
    for (var i = 0; i < pointCount; i++) {
      _rest[i] = offsets[i];
      _points[i] = c + offsets[i];
      _prev[i] = _points[i];
      sum += offsets[i].distance;
    }
    radius = sum / pointCount;
    restArea = _area();
    _measureRest();
    notifyListeners();
  }

  /// 超椭圆轮廓采样：`|x/a|^p + |y/b|^p = 1`。
  ///
  /// [exponent] 取 5 时接近圆角矩形（按钮/卡片）；取 2 时退化为椭圆。
  static List<Offset> superellipse(
    double width,
    double height, {
    double exponent = 5,
  }) {
    final offsets = <Offset>[];
    final halfW = width / 2;
    final halfH = height / 2;
    for (var i = 0; i < pointCount; i++) {
      final t = math.pi * 2 * i / pointCount;
      final c = math.cos(t);
      final s = math.sin(t);
      final x = halfW * (c < 0 ? -1 : 1) * math.pow(c.abs(), 2 / exponent);
      final y = halfH * (s < 0 ? -1 : 1) * math.pow(s.abs(), 2 / exponent);
      offsets.add(Offset(x.toDouble(), y.toDouble()));
    }
    return offsets;
  }

  /// 朝某点施力（拖拽 / 点击冲击）。力随距离衰减。
  void pushFrom(Offset target, double strength, {double falloff = 1.6}) {
    for (var i = 0; i < pointCount; i++) {
      final d = (_points[i] - target).distance;
      final w = math.max(0.0, 1 - d / (radius * falloff));
      if (w <= 0) continue;
      // 目标点正好落在粒子上时方向向量为零，会推不动；退化为沿半径向外推。
      final Offset dir;
      if (d < 1e-3) {
        final radial = _points[i] - center;
        dir = radial.distance < 1e-3
            ? const Offset(0, -1)
            : radial / radial.distance;
      } else {
        dir = (_points[i] - target) / d;
      }
      _points[i] = _points[i] + dir * (strength * w * w);
    }
    notifyListeners();
  }

  /// 整体挤压：沿水平方向拉伸、垂直方向压缩（按下按钮的手感）。
  ///
  /// [amount] 为正表示"压扁"：宽变多、高变少。
  void squash(double amount) {
    for (var i = 0; i < pointCount; i++) {
      final v = _points[i] - center;
      _points[i] = center + Offset(v.dx * (1 + amount), v.dy * (1 - amount));
    }
    notifyListeners();
  }

  /// 走一步物理。[dt] 建议固定 1/120。
  void step(double dt) {
    final p = physics;

    // Verlet 积分（零重力：UI 元素必须锚定）
    for (var i = 0; i < pointCount; i++) {
      final x = _points[i];
      var vx = (x.dx - _prev[i].dx) * p.damping;
      var vy = (x.dy - _prev[i].dy) * p.damping;
      vx = vx.clamp(-5.0, 5.0);
      vy = vy.clamp(-5.0, 5.0);
      _prev[i] = x;
      _points[i] = Offset(x.dx + vx, x.dy + vy);
    }

    // 回位系绳：把每个粒子朝静止位置拉，软体才不漂走也不散架
    for (var i = 0; i < pointCount; i++) {
      final target = center + _rest[i];
      _points[i] = _points[i] + (target - _points[i]) * p.tether;
    }

    const iterations = 6;
    for (var it = 0; it < iterations; it++) {
      for (var i = 0; i < pointCount; i++) {
        _satisfy(i, (i + 1) % pointCount, _edgeLen[i], p.edge);
        _satisfy(i, (i + 2) % pointCount, _bendLen[i], p.bend);
        if (i < pointCount ~/ 2) {
          _satisfy(i, (i + pointCount ~/ 2) % pointCount, _spanLen[i], p.shape);
        }
      }
      _applyPressure(p.pressure);
      _recenter();
    }

    notifyListeners();
  }

  /// Catmull-Rom 闭合样条 → 三次贝塞尔，得到平滑轮廓。
  Path buildPath() {
    final path = Path();
    final first = _points[0];
    path.moveTo(first.dx, first.dy);
    for (var i = 0; i < pointCount; i++) {
      final p0 = _points[(i - 1 + pointCount) % pointCount];
      final p1 = _points[i];
      final p2 = _points[(i + 1) % pointCount];
      final p3 = _points[(i + 2) % pointCount];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      // 末尾那一段会绕回起点，close() 负责收口
      if (i == pointCount - 1) break;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    path.close();
    return path;
  }

  void _satisfy(int i, int j, double rest, double k) {
    final a = _points[i];
    final b = _points[j];
    var dx = b.dx - a.dx;
    var dy = b.dy - a.dy;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < 1e-4) return;
    final c = (d - rest) / d * 0.5 * k;
    dx *= c;
    dy *= c;
    _points[i] = Offset(a.dx + dx, a.dy + dy);
    _points[j] = Offset(b.dx - dx, b.dy - dy);
  }

  double _area() {
    var a = 0.0;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      final q = _points[(i + 1) % pointCount];
      a += p.dx * q.dy - q.dx * p.dy;
    }
    return a * 0.5;
  }

  /// 面积守恒：沿法线修正面积偏差。半流体手感的真正来源。
  void _applyPressure(double k) {
    final gradient = List<Offset>.filled(
      pointCount,
      Offset.zero,
      growable: false,
    );
    var norm = 0.0;
    for (var i = 0; i < pointCount; i++) {
      final before = _points[(i + pointCount - 1) % pointCount];
      final after = _points[(i + 1) % pointCount];
      final gx = (after.dy - before.dy) * 0.5;
      final gy = (before.dx - after.dx) * 0.5;
      gradient[i] = Offset(gx, gy);
      norm += gx * gx + gy * gy;
    }
    final delta = ((restArea - _area()) / (norm == 0 ? 1 : norm)).clamp(
      -0.16,
      0.16,
    );
    for (var i = 0; i < pointCount; i++) {
      _points[i] = _points[i] + gradient[i] * (delta * k);
    }
  }

  void _recenter() {
    var x = 0.0;
    var y = 0.0;
    for (final p in _points) {
      x += p.dx;
      y += p.dy;
    }
    center = Offset(x / pointCount, y / pointCount);
  }

  void _measureRest() {
    for (var i = 0; i < pointCount; i++) {
      _edgeLen[i] = (_rest[(i + 1) % pointCount] - _rest[i]).distance;
      _bendLen[i] = (_rest[(i + 2) % pointCount] - _rest[i]).distance;
      _spanLen[i] =
          (_rest[(i + pointCount ~/ 2) % pointCount] - _rest[i]).distance;
    }
  }
}
