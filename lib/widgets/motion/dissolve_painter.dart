/// 溶解翻页（E3 · atlas noise-dissolve-reveal 降编移植）。
///
/// **降编语义**：翻页是手势进度驱动——上层页（当前页）被持续毛边噪声边缘
/// 逐寸「吃掉」露出下层页；边缘蠕动只在翻动进行中发生（相位由 progress
/// 积分驱动，非 Timer），页面静止时边缘冻结（零 CPU）。
///
/// 算法直译 atlas：
/// 1. 256×256 梯度（Perlin）噪声瓦片 ×2，固定种子、3 octaves，模块级
///    lazy 生成一次全书共享（`Float32List` 直接采样，不做 ui.Image 像素读取）；
/// 2. 网格节点取值 `s = dir·(y − frontY) + wander·N(x,y) + crest·C(x)`，
///    `s > 0` 剪掉；`frontY = progress × 页高`；
/// 3. **行采样优化保留**：噪声最大幅度够不到的行直接按基线取值，只对
///    过渡带内的行做噪声采样；
/// 4. 网格穿零点 8-连通追踪成闭合环（saddle 用中心均值裁决，保证每点度 2），
///    包围盒 < 34px 的小环丢弃，Catmull-Rom 平滑闭合；
/// 5. `Path(fillType: evenOdd)` = 外矩形 + 全部闭合环：环内剪掉、环外保留，
///    环可以伸出页矩形（padding 环保证了穿零轮廓的闭合性），evenOdd 自动
///    处理岛/洞奇偶。
///
/// 性能：路径只在 progress/phase/尺寸/方向变化时重建一次（`DissolveReveal`
/// 缓存上一帧 Path），`DissolveEdgePainter.shouldRepaint` 比较路径标识，
/// 静止页零重建。15px 网格起步，实测超预算降 24px（[kDissolveGridSize]）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui'
    show
        Canvas,
        Offset,
        Paint,
        PaintingStyle,
        Path,
        PathFillType,
        Rect,
        Size,
        StrokeCap,
        StrokeJoin;

import 'package:flutter/material.dart'
    show
        BuildContext,
        ClipPath,
        Colors,
        CustomClipper,
        CustomPaint,
        CustomPainter,
        LayoutBuilder,
        State,
        StatefulWidget,
        Widget;

/// 溶解网格步长（px，atlas noise-dissolve 同源）。低端机超 2ms/帧预算时
/// 降用 [kDissolveGridSizeCoarse]。
const double kDissolveGridSize = 15.0;

/// 降档网格步长（px）。
const double kDissolveGridSizeCoarse = 24.0;

/// 小环丢弃阈值（px）：包围盒最长边小于它的闭合环直接丢弃（atlas 同值），
/// 避免碎屑路径拖慢 draw。
const double kDissolveMinLoopPx = 34.0;

/// 高频蠕动幅度（px）：毛边的细碎抖动。
const double kDissolveWanderAmp = 10.0;

/// 低频波幅（px）：边缘整体的大尺度起伏（crest 只随 x 变化）。
const double kDissolveCrestAmp = 22.0;

/// 蠕动相位增益：翻动进度每推进 1，噪声采样窗沿 x 平移的像素数。
/// 相位由 `progress` 的微分积分驱动（[DissolveReveal] 内），翻动停止即冻结。
const double kDissolvePhaseGain = 72.0;

/// 高频噪声特征尺度（px）。
const double _wanderFreq = 1 / 46;

/// 低频波特征尺度（px）与固定 y 切片（crest 只随 x 变化）。
const double _crestFreq = 1 / 120;
const double _crestSliceV = 137.3;

/// 两张噪声瓦片：固定种子的 3-octave 梯度噪声，首次访问时生成（全书共享）。
final Float32List _tileA = _buildNoiseTile(0x9E3779B9);
final Float32List _tileB = _buildNoiseTile(0x1F123BB5);

/// 字段缓冲复用：翻动中每帧重算网格场，不重复分配（单线程 UI 安全）。
Float64List _field = Float64List(0);

Int32List _permutation(int seed) {
  final rnd = math.Random(seed);
  final p = List<int>.generate(256, (i) => i);
  for (var i = 255; i > 0; i--) {
    final j = rnd.nextInt(i + 1);
    final t = p[i];
    p[i] = p[j];
    p[j] = t;
  }
  final out = Int32List(512);
  for (var i = 0; i < 512; i++) {
    out[i] = p[i & 255];
  }
  return out;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

double _grad2(int hash, double x, double y) {
  switch (hash & 7) {
    case 0:
      return x + y;
    case 1:
      return -x + y;
    case 2:
      return x - y;
    case 3:
      return -x - y;
    case 4:
      return x;
    case 5:
      return -x;
    case 6:
      return y;
    default:
      return -y;
  }
}

/// 周期化 2D Perlin：晶格按 [period] 取模，保证瓦片无缝平铺。
double _perlinPeriodic(Int32List perm, double u, double v, int period) {
  final xi = u.floor();
  final yi = v.floor();
  final xf = u - xi;
  final yf = v - yi;
  final x0 = ((xi % period) + period) % period;
  final x1 = (x0 + 1) % period;
  final y0 = ((yi % period) + period) % period;
  final y1 = (y0 + 1) % period;
  final fu = _fade(xf);
  final fv = _fade(yf);
  final aa = perm[perm[x0] + y0];
  final ab = perm[perm[x0] + y1];
  final ba = perm[perm[x1] + y0];
  final bb = perm[perm[x1] + y1];
  final l1 = _lerp(_grad2(aa, xf, yf), _grad2(ba, xf - 1, yf), fu);
  final l2 = _lerp(_grad2(ab, xf, yf - 1), _grad2(bb, xf - 1, yf - 1), fu);
  return _lerp(l1, l2, fv);
}

/// 256×256 噪声瓦片：3 octaves（晶格周期 8/16/32，幅 1/0.5/0.25）预烘焙，
/// 采样时一次双线性取值即是完整的 3-octave 噪声。
Float32List _buildNoiseTile(int seed) {
  final perm = _permutation(seed);
  final tile = Float32List(256 * 256);
  const periods = <int>[8, 16, 32];
  const amps = <double>[1.0, 0.5, 0.25];
  for (var j = 0; j < 256; j++) {
    for (var i = 0; i < 256; i++) {
      var v = 0.0;
      for (var o = 0; o < 3; o++) {
        v +=
            amps[o] *
            _perlinPeriodic(
              perm,
              i / 256 * periods[o],
              j / 256 * periods[o],
              periods[o],
            );
      }
      tile[j * 256 + i] = v / 1.75;
    }
  }
  return tile;
}

double _sampleTile(Float32List tile, double u, double v) {
  u = u.remainder(256);
  if (u < 0) u += 256;
  v = v.remainder(256);
  if (v < 0) v += 256;
  final i = u.floor();
  final j = v.floor();
  var fu = u - i;
  var fv = v - j;
  fu = fu * fu * (3 - 2 * fu);
  fv = fv * fv * (3 - 2 * fv);
  final ii = i.toInt();
  final jj = j.toInt();
  final i1 = (ii + 1) & 255;
  final j1 = (jj + 1) & 255;
  final a = tile[jj * 256 + ii];
  final b = tile[jj * 256 + i1];
  final c = tile[j1 * 256 + ii];
  final d = tile[j1 * 256 + i1];
  return _lerp(_lerp(a, b, fu), _lerp(c, d, fu), fv);
}

/// 溶解裁剪的纯算法核心：给定进度/相位/页面尺寸/吃入方向，产出「剪掉区域」
/// 的闭合环折线列表（Catmull-Rom 平滑前的原始网格穿零点，首尾不重复）。
///
/// - `progress <= 0`：什么也不吃，返回空列表；
/// - `progress >= 1`：整页吃光，返回覆盖全页的单环；
/// - 返回的环全部闭合（链条化时每点入度恰为 2），可直接交给
///   [smoothClosedLoop] / [buildDissolvePath]。
List<List<Offset>> buildDissolveLoops({
  required double progress,
  required double phase,
  required Size size,
  required bool fromTop,
  double gridSize = kDissolveGridSize,
}) {
  final w = size.width;
  final h = size.height;
  if (w <= 0 || h <= 0 || gridSize <= 0) return const <List<Offset>>[];
  final p = progress.clamp(0.0, 1.0);
  if (p <= 0) return const <List<Offset>>[];
  if (p >= 1) {
    return <List<Offset>>[
      <Offset>[Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h)],
    ];
  }

  // front 线与吃入方向：fromTop = 翻向上一页，上缘向下吃；否则下缘向上吃
  //（与 upDown 模式的来向同构）。dir 决定 s 的正方向：s > 0 剪掉。
  final dir = fromTop ? -1.0 : 1.0;
  final frontY = fromTop ? p * h : h * (1 - p);
  final g = gridSize;
  final ampMax = kDissolveWanderAmp + kDissolveCrestAmp;

  // 网格外扩 2 圈：穿零轮廓可以在页矩形外闭合（evenOdd 下伸出页外的环
  // 不影响裁剪结果，页内区域才是有效区）。
  const padCells = 2;
  final originX = -padCells * g;
  final originY = -padCells * g;
  final cols = ((w + 2 * padCells * g) / g).ceil() + 1;
  final rows = ((h + 2 * padCells * g) / g).ceil() + 1;

  final needed = cols * rows;
  if (_field.length < needed) _field = Float64List(needed);
  final field = _field;

  // 行采样优化：噪声最大幅度够不到的行（|dir·(y − frontY)| > ampMax）符号
  // 与噪声无关，直接按基线取值，不做噪声采样。所有节点值都做「零吸附」
  //（|s| < eps 时推离 0）：值恰为 0 的节点会让穿零点精确落在网格节点上，
  // 四条相邻边共享同一点（度 4），闭合环链条化会在这里分叉。
  //
  // **强制外环**：最外一圈节点钉在「保留」侧（s<0）。没有它，触及网格
  // 边界的区域（吃入区必然触及下缘）的轮廓会沿网格边界**敞开**——链条化
  // 只能得到一条横贯网格的开链。钉住外环后，所有区域都被围进网格内部，
  // 每条轮廓必然闭合（经典 marching squares 外圈补符号技巧）；闭合段
  // 全部落在页矩形外的 padding 里，不影响页内裁剪结果。
  const snapEps = 1e-6;
  for (var j = 0; j < rows; j++) {
    final y = originY + j * g;
    final base = dir * (y - frontY);
    final rowStart = j * cols;
    final forcedKept = j == 0 || j == rows - 1;
    if (forcedKept) {
      for (var i = 0; i < cols; i++) {
        field[rowStart + i] = -1.0;
      }
      continue;
    }
    if (base > ampMax || base < -ampMax) {
      final v = base.abs() < snapEps ? snapEps : base;
      for (var i = 0; i < cols; i++) {
        // 外环列同样保持强制保留——基线快速路径不得覆盖它。
        field[rowStart + i] = (i == 0 || i == cols - 1) ? -1.0 : v;
      }
      continue;
    }
    for (var i = 0; i < cols; i++) {
      if (i == 0 || i == cols - 1) {
        field[rowStart + i] = -1.0;
        continue;
      }
      final x = originX + i * g;
      final wander =
          kDissolveWanderAmp *
          _sampleTile(
            _tileA,
            (x + phase) * _wanderFreq,
            (y + phase * 0.6) * _wanderFreq,
          );
      final crest =
          kDissolveCrestAmp *
          _sampleTile(_tileB, (x - phase * 0.5) * _crestFreq, _crestSliceV);
      var s = base + wander + crest;
      if (s.abs() < snapEps) s = s >= 0 ? snapEps : -snapEps;
      field[rowStart + i] = s;
    }
  }

  // Marching squares：收集穿零线段；saddle（case 5/10）用中心均值裁决，
  // 保证每个穿零点恰好连着两条线段（8-连通闭合的前提）。
  final segA = <Offset>[];
  final segB = <Offset>[];
  final segAKey = <Offset>[];
  final segBKey = <Offset>[];

  Offset crossH(int i, int j) {
    // 水平网格边：node(i,j) → node(i+1,j)。固定节点顺序，两个相邻 cell
    // 对同一条边算出的穿零点逐位相同（链条化的 key 匹配前提）。
    final va = field[j * cols + i];
    final vb = field[j * cols + i + 1];
    final span = va - vb;
    final t = span.abs() < 1e-12 ? 0.5 : va / span;
    return Offset(originX + (i + t) * g, originY + j * g);
  }

  Offset crossV(int i, int j) {
    final va = field[j * cols + i];
    final vb = field[(j + 1) * cols + i];
    final span = va - vb;
    final t = span.abs() < 1e-12 ? 0.5 : va / span;
    return Offset(originX + i * g, originY + (j + t) * g);
  }

  // 端点直接以 Offset 为 key（位级相等）：同一条边的穿零点由两个相邻
  // cell 用同一份场值重算，逐位相同 → 同 key；不同边上的穿零点坐标不同
  //（零吸附保证穿零点不可能精确落在网格节点上）→ 不同 key，链条化的
  // 度恒为 2。量化取整的 key 反而会把「贴着节点的两个近零穿零点」合并
  // 成度 4（踩过的坑）。
  void emit(Offset a, Offset b) {
    segA.add(a);
    segB.add(b);
    segAKey.add(a);
    segBKey.add(b);
  }

  for (var j = 0; j < rows - 1; j++) {
    for (var i = 0; i < cols - 1; i++) {
      final s00 = field[j * cols + i];
      final s10 = field[j * cols + i + 1];
      final s11 = field[(j + 1) * cols + i + 1];
      final s01 = field[(j + 1) * cols + i];
      final code =
          (s00 > 0 ? 1 : 0) |
          (s10 > 0 ? 2 : 0) |
          (s11 > 0 ? 4 : 0) |
          (s01 > 0 ? 8 : 0);
      if (code == 0 || code == 15) continue;
      final top = crossH(i, j);
      final bottom = crossH(i, j + 1);
      final left = crossV(i, j);
      final right = crossV(i + 1, j);
      switch (code) {
        case 1:
        case 14: // 仅 TL 内 / 仅 TL 外
          emit(left, top);
          break;
        case 2:
        case 13: // 仅 TR 内 / 仅 TR 外
          emit(top, right);
          break;
        case 3:
        case 12: // 上边对 / 左右边对
          emit(left, right);
          break;
        case 4:
        case 11: // 仅 BR 内 / 仅 BR 外
          emit(right, bottom);
          break;
        case 6:
        case 9: // 右边对 / 上下边对
          emit(top, bottom);
          break;
        case 7:
        case 8: // 仅 BL 外 / 仅 BL 内
          emit(bottom, left);
          break;
        case 5: // TL+BR saddle：中心定连通性
          final center = (s00 + s10 + s11 + s01) / 4;
          if (center > 0) {
            emit(top, right); // TR 外口袋
            emit(bottom, left); // BL 外口袋
          } else {
            emit(left, top); // TL 内口袋
            emit(right, bottom); // BR 内口袋
          }
          break;
        case 10: // TR+BL saddle
          final center = (s00 + s10 + s11 + s01) / 4;
          if (center > 0) {
            emit(left, top); // TL 外口袋
            emit(right, bottom); // BR 外口袋
          } else {
            emit(top, right); // TR 内口袋
            emit(bottom, left); // BL 内口袋
          }
          break;
      }
    }
  }

  if (segA.isEmpty) return const <List<Offset>>[];

  // 端点 → 线段索引；每点恰有两条线段，逐段游走即得闭合环（8-连通追踪）。
  final byPoint = <Offset, List<int>>{};
  for (var s = 0; s < segA.length; s++) {
    (byPoint[segAKey[s]] ??= <int>[]).add(s);
    (byPoint[segBKey[s]] ??= <int>[]).add(s);
  }
  final used = List<bool>.filled(segA.length, false);
  final loops = <List<Offset>>[];
  for (var s = 0; s < segA.length; s++) {
    if (used[s]) continue;
    used[s] = true;
    final loop = <Offset>[segA[s]];
    var curKey = segBKey[s];
    var curPt = segB[s];
    final startKey = segAKey[s];
    while (curKey != startKey) {
      loop.add(curPt);
      var next = -1;
      final cands = byPoint[curKey];
      if (cands == null) break;
      for (final c in cands) {
        if (!used[c]) {
          next = c;
          break;
        }
      }
      if (next < 0) break; // 防御：理论上不可达（度恒 2）
      used[next] = true;
      if (segAKey[next] == curKey) {
        curKey = segBKey[next];
        curPt = segB[next];
      } else {
        curKey = segAKey[next];
        curPt = segA[next];
      }
    }
    if (loop.length < 3) continue;
    // 小环丢弃：包围盒最长边 < 34px 的碎屑环（atlas 同值）。
    var minX = loop[0].dx;
    var maxX = minX;
    var minY = loop[0].dy;
    var maxY = minY;
    for (final pt in loop) {
      if (pt.dx < minX) minX = pt.dx;
      if (pt.dx > maxX) maxX = pt.dx;
      if (pt.dy < minY) minY = pt.dy;
      if (pt.dy > maxY) maxY = pt.dy;
    }
    if (math.max(maxX - minX, maxY - minY) < kDissolveMinLoopPx) continue;
    loops.add(loop);
  }
  return loops;
}

/// 闭合环折线的 Catmull-Rom 平滑：每相邻两点一段三次贝塞尔，
/// 切线取左右邻点差的一半（经 1/6 控制点系数）。
Path smoothClosedLoop(List<Offset> pts) {
  final n = pts.length;
  final path = Path()..moveTo(pts[0].dx, pts[0].dy);
  for (var i = 0; i < n; i++) {
    final p0 = pts[(i - 1 + n) % n];
    final p1 = pts[i];
    final p2 = pts[(i + 1) % n];
    final p3 = pts[(i + 2) % n];
    final c1x = p1.dx + (p2.dx - p0.dx) / 6;
    final c1y = p1.dy + (p2.dy - p0.dy) / 6;
    final c2x = p2.dx - (p3.dx - p1.dx) / 6;
    final c2y = p2.dy - (p3.dy - p1.dy) / 6;
    path.cubicTo(c1x, c1y, c2x, c2y, p2.dx, p2.dy);
  }
  path.close();
  return path;
}

/// 溶解裁剪路径：`Path(evenOdd)` = 页矩形 + 全部闭合环（环内 = 剪掉区域）。
/// 交给 [ClipPath] 直接剪上层页。
Path buildDissolvePath({
  required double progress,
  required double phase,
  required Size size,
  required bool fromTop,
  double gridSize = kDissolveGridSize,
}) {
  final path = Path()..fillType = PathFillType.evenOdd;
  path.addRect(Rect.fromLTWH(0, 0, size.width, size.height));
  final loops = buildDissolveLoops(
    progress: progress,
    phase: phase,
    size: size,
    fromTop: fromTop,
    gridSize: gridSize,
  );
  for (final loop in loops) {
    path.addPath(smoothClosedLoop(loop), Offset.zero);
  }
  return path;
}

/// 溶解翻页包装：把 [child]（上层页）按 [progress] 被毛边噪声边缘吃掉。
///
/// - `progress`：0..1，被吃比例（readerTurnFrame 的 dissolve 帧）；
/// - `fromTop`：吃入方向——翻向上一页从上缘向下吃，翻向下一页从下缘向上吃
///   （与 upDown 模式的来向同构）；
/// - 蠕动相位在内部由 progress 积分推进：翻动进行中边缘蠕动，静止冻结。
class DissolveReveal extends StatefulWidget {
  const DissolveReveal({
    super.key,
    required this.progress,
    required this.fromTop,
    this.child,
  });

  final double progress;
  final bool fromTop;
  final Widget? child;

  @override
  State<DissolveReveal> createState() => _DissolveRevealState();
}

class _DissolveRevealState extends State<DissolveReveal> {
  double _phase = 0;
  Path? _keptPath;
  Path? _edgePath;
  double _builtProgress = -1;
  double _builtPhase = -1;
  bool _builtFromTop = false;
  Size _builtSize = Size.zero;

  @override
  void didUpdateWidget(covariant DissolveReveal old) {
    super.didUpdateWidget(old);
    // 蠕动相位随 progress 积分推进（progress 微分驱动，非 Timer）。
    _phase += (widget.progress - old.progress).abs() * kDissolvePhaseGain;
  }

  /// progress/phase/方向/尺寸都未变 → 复用上一帧 Path（静止零重建）。
  void _rebuild(Size size) {
    if (size == _builtSize &&
        widget.progress == _builtProgress &&
        _phase == _builtPhase &&
        widget.fromTop == _builtFromTop &&
        _keptPath != null) {
      return;
    }
    _builtSize = size;
    _builtProgress = widget.progress;
    _builtPhase = _phase;
    _builtFromTop = widget.fromTop;
    final loops = buildDissolveLoops(
      progress: widget.progress,
      phase: _phase,
      size: size,
      fromTop: widget.fromTop,
    );
    final kept = Path()..fillType = PathFillType.evenOdd;
    final edge = Path();
    kept.addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    for (final loop in loops) {
      final smooth = smoothClosedLoop(loop);
      kept.addPath(smooth, Offset.zero);
      edge.addPath(smooth, Offset.zero);
    }
    _keptPath = kept;
    _edgePath = edge;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _rebuild(size);
        return CustomPaint(
          foregroundPainter: DissolveEdgePainter(edgePath: _edgePath!),
          child: ClipPath(
            clipper: _DissolveClip(_keptPath!),
            child: widget.child,
          ),
        );
      },
    );
  }
}

class _DissolveClip extends CustomClipper<Path> {
  const _DissolveClip(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_DissolveClip old) => old.path != path;
}

/// 毛边羽化描边：沿轮廓三道由粗到细、由淡到浓的黑色低透明度描边。
/// 颜色沿用本文件所在 reader 翻页层的既有语言（`reader_pager._CurlWrapper`
/// 的折痕阴影同为黑色低透），不注入阅读主题色——溶解尘边在日夜两套主题下
/// 都退隐为「纸边阴影」。
class DissolveEdgePainter extends CustomPainter {
  DissolveEdgePainter({required this.edgePath});

  /// 轮廓环路径（不含页矩形）。
  final Path edgePath;

  @override
  void paint(Canvas canvas, Size size) {
    const passes = <(double, double)>[(6.0, 0.05), (3.0, 0.10), (1.4, 0.16)];
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final (width, alpha) in passes) {
      paint.strokeWidth = width;
      paint.color = Colors.black.withValues(alpha: alpha);
      canvas.drawPath(edgePath, paint);
    }
  }

  @override
  bool shouldRepaint(DissolveEdgePainter old) => old.edgePath != edgePath;
}
