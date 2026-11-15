import 'package:flutter/animation.dart';

/// 交错编排纯函数（effect-atlas 移植 · E0 基建）。
///
/// 两种编排语义，按场景二选一：
/// - [staggeredInterval]：单控制器 + [Interval]——共享时钟，起点交错、
///   **全部同时落定**（item i 从 `base + i·unit` 起跑，到 total 末尾结束）。
///   用法：`CurvedAnimation(parent: controller, curve: staggeredInterval(...))`，
///   曲线族（如 `Fx.glide`）再用一层 `CurveTween` 或 `Interval(curve:)` 叠加。
/// - [staggeredDelay]：给每个 item 算 `AnimationController.forward(delay:)`
///   的延迟——各 item 保持自己的完整时长，起点与终点都交错。
///
/// 两者都是纯函数，不持有状态、不读 MediaQuery；index 从 0 起。
/// 「减少动效」时编排由消费方直跳终态（跳过 stagger 本身），本文件不门控。
///
/// 单 item 起点越过 [total] 时（index 给多了），begin 被夹到 `1-ε`：
/// 该 item 在窗口内几乎全程停在 0、末帧落定。不能返回 `Interval(1, 1)`——
/// 那会在 t=1 时触发 `(t-begin)/(end-begin)` 的 0/0（debug 断言炸）。
Interval staggeredInterval(
  int index, {
  required Duration base,
  required Duration unit,
  required Duration total,
}) {
  assert(index >= 0, 'index 从 0 起');
  assert(total.inMicroseconds > 0, 'total 必须为正');
  assert(
    base.inMicroseconds >= 0 && unit.inMicroseconds >= 0,
    'base/unit 不能为负',
  );
  final int start = base.inMicroseconds + unit.inMicroseconds * index;
  final double begin = start / total.inMicroseconds;
  if (begin <= 0.0) return Interval(0.0, 1.0);
  if (begin >= 1.0) return const Interval(_maxBegin, 1.0);
  return Interval(begin, 1.0);
}

/// begin 的上限：1 的浮点安全邻域（见 [staggeredInterval] 注释）。
const double _maxBegin = 1.0 - 1e-9;

Duration staggeredDelay(
  int index, {
  required Duration base,
  required Duration unit,
}) {
  assert(index >= 0, 'index 从 0 起');
  assert(
    base.inMicroseconds >= 0 && unit.inMicroseconds >= 0,
    'base/unit 不能为负',
  );
  if (index <= 0 || unit.inMicroseconds == 0) return base;
  return base + unit * index;
}
