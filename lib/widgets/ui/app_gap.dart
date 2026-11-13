import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';

/// 间距刻度档位（批次⑤ 全库 gap 收敛）：只暴露刻度内的值，杜绝第 N+1 个档。
enum AppGapSize {
  s2,
  s4,
  s6,
  s8,
  s12,
  s16,
  s20,
  s24,
  s32,
  s40,
  s48,
  s64,
}

/// 裸 `SizedBox` gap 的全站替身（design.md §4.5 间距刻度）：
///
/// - `AppGap.v(..)` 竖向（Column / children 列表里撑行距）；
/// - `AppGap.h(..)` 横向（Row 里撑列距）。
///
/// 尺寸走 [AppMetrics] 刻度（实例由本组件自取 `AppMetrics.standard`——
/// 间距与亮度无关，深浅两套同值），调用点保持 `const` 可用。
class AppGap extends StatelessWidget {
  const AppGap.v(this.size, {super.key}) : _horizontal = false;
  const AppGap.h(this.size, {super.key}) : _horizontal = true;

  final AppGapSize size;
  final bool _horizontal;

  double _extent(AppMetrics m) => switch (size) {
        AppGapSize.s2 => m.s2,
        AppGapSize.s4 => m.s4,
        AppGapSize.s6 => m.s6,
        AppGapSize.s8 => m.s8,
        AppGapSize.s12 => m.s12,
        AppGapSize.s16 => m.s16,
        AppGapSize.s20 => m.s20,
        AppGapSize.s24 => m.s24,
        AppGapSize.s32 => m.s32,
        AppGapSize.s40 => m.s40,
        AppGapSize.s48 => m.s48,
        AppGapSize.s64 => m.s64,
      };

  @override
  Widget build(BuildContext context) {
    final double d = _extent(AppMetrics.standard);
    return _horizontal ? SizedBox(width: d) : SizedBox(height: d);
  }
}
