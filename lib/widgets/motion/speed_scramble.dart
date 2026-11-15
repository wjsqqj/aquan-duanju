import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_metrics.dart';
import 'decode_reveal.dart' show kScrambleCharset;
import 'glyph_metrics.dart';

/// 速度归一基准：energy = min(1, speed / 2000)（atlas scroll-speed-scramble
/// 的 speed/2000 线性归一，px/s）。kit 常量（atlas 出处）。
const double kScrambleSpeedNorm = 2000;

/// 速度表时间常数：120ms 指数衰减（atlas「速度表 120ms 时间常数」）。
const int kScrambleDecayMs = 120;

/// 乱码 tick：42ms 一步（atlas「乱码 tick≈42ms」——读作滚动代码而非闪烁）。
const int kScrambleTickMs = 42;

/// 乱码密度上限（atlas scrambleDensity 默认 0.67：满能量时 67% 字符位乱码）。
const double kScrambleDensity = 0.67;

/// 复原窗口：停输入后 672ms 内完成逐字从左复原（atlas scrambleDuration
/// 672ms）。长文本按窗口压缩 stagger，不静默超限。
const int kScrambleRestoreMs = 672;

/// 复原逐字 stagger：14ms（atlas 聚拢段 14ms stagger 的左向等效值，PRD
/// 指定「逐字从左复原」）。
const int kScrambleRestoreStaggerMs = 14;

/// 触发乱码的 energy 地板（atlas「energy > 0.02 起 Ticker」的显示地板
/// 降编：慢滚（<400px/s）零变化——AC 要求慢滚标题纹丝不动，而 0.67×
/// 0.15 的门限仍会偶发单字闪码；0.2 地板 = 400px/s 以下完全不进乱码态。
/// 起表口径同为 0.2，停表在复原窗口完成时统一归静（_calmDown），不设
/// 独立的 0.02 停表线）。
const double kScrambleDisplayFloor = 0.2;

/// 字符 i 在 step 拍是否为噪声位（atlas 公式直译）：
/// `((i*13 + step*7) mod 100) / 100 < density * energy`。
@visibleForTesting
bool fxScrambleNoise(int index, int step, double density, double energy) {
  final double gate = ((index * 13 + step * 7) % 100) / 100;
  return gate < density * energy;
}

/// 字符 i 在 step 拍的乱码字形（atlas 确定性字符表直译）：
/// `charset[(i*7 + step*13) % len]`——同字符同拍必同字形（确定性模式，
/// 读作「滚动代码」；atlas 纪律：不用真随机）。
@visibleForTesting
String fxScrambleGlyph(int index, int step) {
  final int pos = (index * 7 + step * 13) % kScrambleCharset.length;
  return kScrambleCharset[pos];
}

/// 滚速乱码标题（effect-atlas scroll-speed-scramble 移植 · E5）。
///
/// 聚合页 AppBar 标题：滚动速度驱动乱码密度——滚得越快乱得越狠，慢下来
/// 指数衰减复原，静止 = 正常标题：
/// - 速度源 [velocity]（px/s，调用方经 `NotificationListener` 计算传入）；
///   energy = min(1, |v|/[kScrambleSpeedNorm]) **只升不降**（从输入），
///   之后按 [kScrambleDecayMs] 时间常数指数衰减；
/// - energy > [kScrambleDisplayFloor] 才进乱码态：单 Ticker，每
///   [kScrambleTickMs] 一步，字符位命中 [fxScrambleNoise] 时显示
///   [fxScrambleGlyph]（慢滚零变化）；
/// - energy 衰减回地板以下：**复原窗口**——冻结当前画面，逐字从左复原
///   （[kScrambleRestoreStaggerMs] stagger，整窗 ≤[kScrambleRestoreMs]），
///   完成后切回普通 `Text`（与静态渲染逐像素一致）并停表；
/// - **字宽冻结**：乱码字形与真字符取最大实测宽（[FxGlyphMeter]，与
///   FxDecodeReveal 同手法），乱码期间行宽不抖；
/// - `Semantics(label: 完整标题)`——读屏只读真字，不读乱码副本。
///
/// 门控（AC20）：「减少动效」纯静态标题（不装 Ticker、不订阅速度）。
class FxSpeedScramble extends StatefulWidget {
  const FxSpeedScramble({
    super.key,
    required this.text,
    required this.velocity,
    this.style,
    this.maxLines = 1,
  });

  /// 标题文本。
  final String text;

  /// 滚动速度源（px/s 绝对值由组件内部取 abs）。
  final ValueListenable<double> velocity;

  /// 标题样式；缺省取 `DefaultTextStyle`（AppBar 已给标题上样式）。
  final TextStyle? style;

  final int maxLines;

  @override
  State<FxSpeedScramble> createState() => _FxSpeedScrambleState();
}

class _FxSpeedScrambleState extends State<FxSpeedScramble>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;

  /// 速度表：energy 只升不降（从输入），随帧指数衰减。
  double _energy = 0;

  /// 乱码步号（每 [kScrambleTickMs] +1）。
  int _step = 0;
  double _tickAccumMs = 0;

  /// 乱码态 / 复原态。
  bool _scrambling = false;
  bool _restoring = false;
  double _restoreMs = 0;

  /// 复原起点冻结帧（复原期间的未锁定字符继续显示它）。
  List<String>? _frozenGlyphs;

  /// 复原 stagger（按字符数压缩进 672ms 窗口）。
  double _restoreStaggerMs = kScrambleRestoreStaggerMs.toDouble();

  List<String> _chars = const <String>[];
  bool _staticOnly = false;
  bool _wired = false;

  final FxGlyphMeter _meter = FxGlyphMeter();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _meter.updateDirection(Directionality.of(context));
    if (_wired) return;
    _wired = true;
    // 门控（AC20）：reduceMotion 纯静态标题，不订阅速度源、不装 Ticker。
    if (AppMetrics.reduceMotionEnabled(context)) {
      _staticOnly = true;
      return;
    }
    widget.velocity.addListener(_onVelocity);
    _prepare();
  }

  @override
  void didUpdateWidget(covariant FxSpeedScramble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style != oldWidget.style) _meter.clearCache();
    // reduceMotion 态不订阅速度（AC20 静态承诺，含换源重挂的场景）。
    if (!_staticOnly && !identical(oldWidget.velocity, widget.velocity)) {
      oldWidget.velocity.removeListener(_onVelocity);
      widget.velocity.addListener(_onVelocity);
    }
    if (widget.text != oldWidget.text) {
      _prepare();
      _calmDown();
      setState(() {});
    }
  }

  void _prepare() {
    _chars = widget.text.characters.toList(growable: false);
    final int n = _chars.length;
    _restoreStaggerMs = n <= 1
        ? 0
        : math.min(
            kScrambleRestoreStaggerMs.toDouble(),
            kScrambleRestoreMs / (n - 1),
          );
  }

  /// 回到完全静止态（换文本 / 复原完成 / 慢滚衰减归静）。
  void _calmDown() {
    _energy = 0;
    _step = 0;
    _tickAccumMs = 0;
    _scrambling = false;
    _restoring = false;
    _restoreMs = 0;
    _frozenGlyphs = null;
    _stopTicker();
  }

  void _onVelocity() {
    if (!mounted || _staticOnly) return;
    final double v = widget.velocity.value.abs();
    if (v <= 0) return;
    final double energy = math.min(1, v / kScrambleSpeedNorm);
    if (energy > _energy) _energy = energy;
    if (_energy <= kScrambleDisplayFloor) return; // 慢滚零变化
    // 高能量输入：离开复原态，重进乱码态（重建 Ticker 由首帧驱动重绘）。
    if (_restoring) {
      _restoring = false;
      _frozenGlyphs = null;
      _restoreMs = 0;
    }
    _scrambling = true;
    _ensureTicker();
  }

  void _ensureTicker() {
    if (_ticker != null) {
      if (!_ticker!.isActive) {
        _lastElapsed = Duration.zero;
        _ticker!.start();
      }
      return;
    }
    _ticker = Ticker(_onTick);
    _lastElapsed = Duration.zero;
    _ticker!.start();
  }

  void _stopTicker() {
    if (_ticker == null) return;
    if (_ticker!.isActive) _ticker!.stop();
  }

  void _onTick(Duration elapsed) {
    final Duration dt = elapsed == Duration.zero
        ? Duration
              .zero // 起表首拍不衰减（ticker elapsed 从 0 起跑）
        : (_lastElapsed == Duration.zero ? elapsed : elapsed - _lastElapsed);
    _lastElapsed = elapsed;
    final double dtMs = dt.inMicroseconds / 1000;

    // energy 指数衰减（120ms 时间常数，帧率无关）。
    _energy *= math.exp(-dtMs / kScrambleDecayMs);

    if (_scrambling) {
      _tickAccumMs += dtMs;
      while (_tickAccumMs >= kScrambleTickMs) {
        _tickAccumMs -= kScrambleTickMs;
        _step++;
      }
      if (_energy <= kScrambleDisplayFloor) {
        // 跌破地板：进入复原窗口——冻结当前画面，逐字从左复原。
        _scrambling = false;
        _restoring = true;
        _restoreMs = 0;
        _frozenGlyphs = _currentGlyphs();
      }
      setState(() {});
      return;
    }
    // 复原窗口：未锁定字符显示冻结帧，锁定逐个换真字。
    _restoreMs += dtMs;
    final double totalMs = _restoreStaggerMs * math.max(0, _chars.length - 1);
    if (_restoreMs >= totalMs) {
      _calmDown();
    }
    setState(() {});
  }

  /// 当前帧每个字符位显示的字符串（乱码态）。
  List<String> _currentGlyphs() => <String>[
    for (int i = 0; i < _chars.length; i++)
      fxScrambleNoise(i, _step, kScrambleDensity, _energy)
          ? fxScrambleGlyph(i, _step)
          : _chars[i],
  ];

  TextStyle _resolveStyle(BuildContext context) =>
      widget.style ?? DefaultTextStyle.of(context).style;

  @override
  Widget build(BuildContext context) {
    final bool live = !_staticOnly && (_scrambling || _restoring);
    if (!live) {
      // 静态直出（reduceMotion / 静止 / 复原完成）：普通 Text。
      return Text(
        widget.text,
        style: _resolveStyle(context),
        maxLines: widget.maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: _buildCells(_resolveStyle(context)),
    );
  }

  Widget _buildCells(TextStyle style) {
    final List<String>? frozen = _frozenGlyphs;
    final List<String> glyphs = _restoring
        ? const <String>[]
        : _currentGlyphs();
    final List<String> shown = <String>[
      for (int i = 0; i < _chars.length; i++)
        if (_restoring && frozen != null)
          _restoreMs >= _restoreStaggerMs * i ? _chars[i] : frozen[i]
        else
          glyphs[i],
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < _chars.length; i++) _cell(i, shown[i], style),
      ],
    );
  }

  /// 单字符单元格：冻结宽高（真字符与本格可能字形取最大宽）。
  Widget _cell(int index, String shown, TextStyle style) {
    final Size size = _meter.cellSize(
      char: _chars[index],
      // 本格可能出现的字形全集（step 跨全表循环 → 字符集全部字符都可能）。
      glyphCandidates: kScrambleCharset.characters,
      style: style,
    );
    return SizedBox.fromSize(
      size: size,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(shown, style: style, maxLines: 1, softWrap: false),
      ),
    );
  }

  @override
  void dispose() {
    widget.velocity.removeListener(_onVelocity);
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  // ---- 测试口（test/motion/speed_scramble_test.dart）----

  @visibleForTesting
  double get debugEnergy => _energy;

  @visibleForTesting
  bool get debugScrambling => _scrambling;

  @visibleForTesting
  bool get debugRestoring => _restoring;

  @visibleForTesting
  bool get debugTickerActive => _ticker?.isActive ?? false;

  @visibleForTesting
  bool get debugStaticOnly => _staticOnly;

  @visibleForTesting
  int get debugStep => _step;

  @visibleForTesting
  List<double> debugCellWidths(TextStyle style) => <double>[
    for (int i = 0; i < _chars.length; i++)
      _meter
          .cellSize(
            char: _chars[i],
            glyphCandidates: kScrambleCharset.characters,
            style: style,
          )
          .width,
  ];
}
