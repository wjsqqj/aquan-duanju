import 'package:flutter/animation.dart';

/// EffectKit 曲线族（effect-atlas 移植 · E0 基建）。
///
/// atlas 全库统一的时间语言：快起软落缓动族 + 过冲弹簧 + 强 in-out 开合。
/// 常数取自 atlas `effect.js` 顶部规格注释的 cubic-bezier 定义。
///
/// 纪律（对齐 NEVER DO #5 的姊妹条）：**时长走 `AppMetrics`，曲线走这里**——
/// 业务文件不得裸写 `Cubic(...)`；kit 文件（本目录）是曲线常量的唯一例外。
abstract final class Fx {
  /// 快起软落主曲线（cubic-bezier(.22,1,.36,1)）——atlas 全库默认缓动，
  /// 遮罩翻词等「进入」效果的默认选择。
  static const Curve glide = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 弹簧过冲（cubic-bezier(.28,1.3,.36,1)）——落位带回弹。
  static const Curve spring = Cubic(0.28, 1.3, 0.36, 1.0);

  /// 滑出（cubic-bezier(.33,.55,.2,1)）——离场「先缓后滑」的不对称缓动。
  static const Curve glideOut = Cubic(0.33, 0.55, 0.20, 1.0);

  /// in-out（cubic-bezier(.45,.05,.4,1)）——双向对称的位移过渡。
  static const Curve inOut = Cubic(0.45, 0.05, 0.40, 1.0);

  /// 强 in-out 开合（cubic-bezier(.7,0,.16,1)）——叠卡轮播开合。
  static const Curve dockIn = Cubic(0.70, 0.00, 0.16, 1.0);

  /// 1-(1-t)^4 快出软落（shared-element 转场曲线）。
  ///
  /// 比 `Curves.easeOutQuart`（Cubic 近似）更陡：前 1/4 时程就跑完大半路程。
  /// atlas 700ms 页内揭幕用这族；E0 的路由 Hero 沿用页面转场默认时长。
  static const Curve quartOut = _QuarticOut();

  /// 阶梯曲线：`floor(t·steps)/steps`——胶片跳帧 / 像素硬帧共用。
  ///
  /// 与 CSS `steps(n, jump-end)` 同义：t∈[0,1) 期间停在最近的阶上，只有
  /// t=1 落到 1。n=1 时整段停在起点、末帧才落终值；n<=0 按单阶处理。
  /// 返回值只会是 k/steps（k=0..steps），不会超出 [0,1]。
  static Curve stepped(int steps) => _Stepped(steps);
}

/// `quartOut` 的实现：transform = 1-(1-t)^4，纯函数无状态。
class _QuarticOut extends Curve {
  const _QuarticOut();

  @override
  double transformInternal(double t) {
    final double u = 1.0 - t;
    return 1.0 - u * u * u * u;
  }
}

/// `stepped` 的实现：transform = floor(t·steps)/steps，纯函数无状态。
class _Stepped extends Curve {
  const _Stepped(this.steps);

  final int steps;

  @override
  double transformInternal(double t) {
    final int n = steps <= 0 ? 1 : steps;
    final double stepped = (t * n).floorToDouble() / n;
    // 数学上已在 [0,1]，显式夹取防浮点边缘（如 t 略大于 1 的调用口）。
    if (stepped <= 0.0) return 0.0;
    if (stepped >= 1.0) return 1.0;
    return stepped;
  }
}
