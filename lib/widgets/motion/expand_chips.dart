import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../tv_scope.dart';

/// 组间/组内 chips 交错：30ms（atlas expanding-dock 分段节奏；PRD R1 定为
/// kit 常量，与 [fxMotionLag] 同性质的 atlas 出处微拍，微交互内不占五档）。
const Duration fxExpandStagger = Duration(milliseconds: 30);

/// 每组基础拍：150ms（五档 hover 档值；单 controller 总长 = 150ms·组数，
/// design §2 直译）。
const Duration fxExpandGroupBase = Duration(milliseconds: 150);

/// 编排总长上限：1200ms（PRD「单 controller 总长 ≤1.2s」）。
const Duration fxExpandTotalCap = Duration(milliseconds: 1200);

/// 外圈组滞后比：外圈比中段晚起**总长的 15%**（atlas expanding-dock
/// middleDuration=15% 直译）。
const double fxExpandMiddleLead = 0.15;

/// 组数上限（cap 之后总长封在 [fxExpandTotalCap]，交错不再拉长）。
const int kExpandChipsMaxGroups = 8;

/// 弹入位移：12px，自下而上（design §2「位移 y 12px」；幅度语义，非布局
/// 间距，勿与 AppSpacing.s12 混用）。
const double fxExpandRisePx = 12;

/// begin 的浮点安全邻域（同 fx_stagger 惯例：Interval(1,1) 会在
/// `(t-begin)/(end-begin)` 产生 0/0 断言）。
const double _maxBegin = 1.0 - 1e-9;

/// 单 controller 总长：150ms·组数，cap 1200ms（design §2）。
@visibleForTesting
Duration fxExpandTotalFor(int groups) {
  final int n = groups < 1
      ? 1
      : (groups > kExpandChipsMaxGroups ? kExpandChipsMaxGroups : groups);
  final Duration total = fxExpandGroupBase * n;
  return total > fxExpandTotalCap ? fxExpandTotalCap : total;
}

/// 组 [group] 内第 [chip] 枚的窗口（共享时钟、同时落定语义，同
/// staggeredInterval）：前 1/3 组为「中段」先起（起点 = 组序×stagger），
/// 其余为「外圈」滞后 15% 总长起跑（起点 = middleLead + 组序×stagger）；
/// 组内 chips 再按 stagger 逐枚递进（起点 += chip 序×stagger）。atlas
/// expanding-dock「中段先行、外圈跟进」的分段直译。
@visibleForTesting
Interval fxExpandChipWindow(int group, int chip, int groups) {
  final Duration total = fxExpandTotalFor(groups);
  final int middleCount = math.max(1, groups ~/ 3);
  final Duration groupStart = group < middleCount
      ? fxExpandStagger * group
      : (total * fxExpandMiddleLead) + fxExpandStagger * group;
  final Duration start = groupStart + fxExpandStagger * chip;
  final double begin = start.inMicroseconds / total.inMicroseconds;
  if (begin <= 0.0) return const Interval(0.0, 1.0);
  if (begin >= 1.0) return const Interval(_maxBegin, 1.0);
  return Interval(begin, 1.0);
}

/// 组 [group] 内第 [chip] 枚的 opacity 窗口：窗口前 50% 完成（design §2
/// 「opacity 0→1（前 50% 完成）」），线性。
@visibleForTesting
Interval fxExpandChipOpacityWindow(int group, int chip, int groups) {
  final Interval window = fxExpandChipWindow(group, chip, groups);
  return Interval(window.begin, window.begin + (1.0 - window.begin) / 2);
}

/// 筛选 chips 组「中段先行、外圈跟进」弹性弹入（effect-atlas expanding-dock
/// 移植 · E7，降编）。
///
/// 编排：单 [AnimationController] 总长 = 150ms·组数（cap 1200ms）；前 1/3
/// 组为「中段」先起、其余组滞后总长 15% 跟进，组内 chips 再按 30ms 递进
/// （窗口见 [fxExpandChipWindow] / [fxExpandChipOpacityWindow]，共享时钟
/// 同时落定）；曲线 [Curves.easeOutBack]（atlas back.out(1.7) 的内置近似，
/// 过冲约 10%）——chips 自下而上 12px 弹入、opacity 前 50% 完成。
///
/// 触发：**挂载即播一次**。筛选页面板数据到达（首次加载完成 / 换 genre
/// 重载完成）都会先切骨架屏再回来，本组件随面板内容重挂载，天然「每次
/// 数据到达播一次」；选择变化只重建子树、不重挂载，不重播。
///
/// 布局零变化：参与弹入的 chip 由 [FxExpandChip] 包裹，只做
/// [Transform.translate] + [Opacity]，落定后（含 reduceMotion / TV）直接
/// 返回原 child，包装层消失，稳态与无动效渲染等价。
///
/// 门控（AC20）：「减少动效」/ TV 直出静态（不装 controller）。
class FxExpandChips extends StatefulWidget {
  const FxExpandChips({
    super.key,
    required this.groupCount,
    required this.child,
  });

  /// chips 组数（筛选面板的行数）。
  final int groupCount;

  /// 面板内容（含各行标题与 chips [Wrap]）。
  final Widget child;

  @override
  State<FxExpandChips> createState() => _FxExpandChipsState();
}

class _FxExpandChipsState extends State<FxExpandChips>
    with SingleTickerProviderStateMixin {
  /// null = 直出形态（reduceMotion / TV）：不装控制器。
  AnimationController? _controller;

  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    _wire();
  }

  void _wire() {
    // 门控（AC20）：reduceMotion / TV 静态直出——焦点导航优先，不抢入场拍。
    if (AppMetrics.reduceMotionEnabled(context) || TvScope.isTvOf(context)) {
      return;
    }
    _controller = AnimationController(
      vsync: this,
      duration: fxExpandTotalFor(widget.groupCount),
    )..forward();
  }

  @override
  void didUpdateWidget(covariant FxExpandChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板正常路径是「骨架屏 → 重挂载」，groupCount 不会原地变化；若发生
    // （消费方复用本组件做其它面板），按新组数重算总长并重播一次。
    if (_controller == null || oldWidget.groupCount == widget.groupCount) {
      return;
    }
    setState(() {
      _controller!.duration = fxExpandTotalFor(widget.groupCount);
      _controller!.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (controller == null) {
      // 直出（reduceMotion / TV）：零包装，与无动效渲染逐像素一致。
      return widget.child;
    }
    // 落定不卸壳（E4/E5 沉淀「壳卸载时机」）：scope 与各 chip 的
    // AnimatedBuilder 保留在树上，tile 侧按 value≥1 裸返回 child，稳态
    // 渲染等价且整棵面板子树不重挂。
    return _FxExpandScope(
      animation: controller,
      groupCount: widget.groupCount,
      child: widget.child,
    );
  }
}

/// 弹入编排的共享时钟下发（[FxExpandChips] → 各 [FxExpandChip]）。
class _FxExpandScope extends InheritedWidget {
  const _FxExpandScope({
    required this.animation,
    required this.groupCount,
    required super.child,
  });

  /// 共享时钟（controller 本体；value 0..1）。
  final Animation<double> animation;

  final int groupCount;

  static _FxExpandScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FxExpandScope>();

  @override
  bool updateShouldNotify(_FxExpandScope old) =>
      old.animation != animation || old.groupCount != groupCount;
}

/// 参与弹入的单个 chip 包裹层（第 [group] 组第 [index] 枚）。
///
/// 只做 Transform.translate + Opacity——布局零变化；作用域外（无
/// [FxExpandChips] 祖先）或直出形态下返回原 child 本身。
class FxExpandChip extends StatelessWidget {
  const FxExpandChip({
    super.key,
    required this.group,
    required this.index,
    required this.child,
  });

  /// 组序（筛选面板行序，0 起）。
  final int group;

  /// 组内 chip 序（0 起，含「全部」chip）。
  final int index;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _FxExpandScope? scope = _FxExpandScope.maybeOf(context);
    if (scope == null) return child;
    return AnimatedBuilder(
      animation: scope.animation,
      builder: (context, _) {
        final Animation<double> master = scope.animation;
        // 落定（value 恰为 1）：裸返回 child，稳态与无动效渲染逐像素一致。
        // 注意只以 value 判定——过冲段 p>1 仍须保留包装，否则弹性回弹被裁。
        if (master.value >= 1.0) return child;
        // 位移窗口（Interval 内线性进度）→ easeOutBack 弹性（过冲约 10%，
        // 即落位前越过终点 ~1.2px 再回）。
        final Interval window = fxExpandChipWindow(
          group,
          index,
          scope.groupCount,
        );
        final double p = Curves.easeOutBack.transform(
          window.transform(master.value),
        );
        // opacity 窗口：前 50% 完成，线性（提前到 1 后 RenderOpacity 恒等渲染）。
        final Interval fade = fxExpandChipOpacityWindow(
          group,
          index,
          scope.groupCount,
        );
        final double opacity = fade.transform(master.value);
        return Transform.translate(
          offset: Offset(0, (1.0 - p) * fxExpandRisePx),
          child: Opacity(opacity: opacity, child: child),
        );
      },
    );
  }
}
