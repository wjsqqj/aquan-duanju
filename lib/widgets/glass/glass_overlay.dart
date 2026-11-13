import 'package:flutter/material.dart';

import '../../theme/app_metrics.dart';
import '../../theme/app_tokens.dart';
import '../../theme/glass_tokens.dart';
import 'app_glass.dart';

// =============================================================================
// 玻璃浮层（父任务 design.md §11.3 / §11.5 第 4 条 / implement.md 1b.6）
//
// 三个入口的共同约定：
// 1. **玻璃外壳建在 route 的 builder 里**，不建在调用方那一侧。`showDialog` /
//    `showModalBottomSheet` 的 builder 才在路由层内，玻璃的采样域才是「被压暗的
//    背后页面」；包在调用方等于包在页面里，采样到的是页面自己的兄弟节点。
// 2. 只换「面」：圆角 / 内边距 / 档位全部取 Token，内容仍是调用方自己的 widget，
//    所以 30+ 处既有 `AlertDialog` 调用点可以逐个迁移，不需要一次换掉契约。
// 3. 不写 `AppGlass.canRefract` 分支——折射 / 雾面两条路径由 `AppGlass` 内部
//    处理（`BackdropFilter` 降级），这里调用的代码在两种能力下完全相同。
// =============================================================================

/// 玻璃 Dialog。
///
/// 不复用上游 `GlassDialog.show`：它的 `actions` 契约（固定按钮位 + 自己的
/// 返回值模型）与项目现有对话框写法不一致，换过去要改所有调用点。这里用原生
/// [Dialog] + [AppGlass] 自绘外壳，可控、也不引入上游类型（AC1b.2）。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext dialogContext) {
      final AppTokens tokens = dialogContext.app;
      final AppMetrics m = tokens.metrics;
      return Dialog(
        // 「面」让给 AppGlass：Dialog 自己的底色 / M3 表面着色会盖住玻璃。
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // 形状与玻璃同圆角：Material 裁剪、点击涟漪都落在同一轮廓上。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(m.radiusLg)),
        ),
        child: AppGlass(
          tier: AppGlassTier.overlay,
          radius: m.radiusLg,
          padding: EdgeInsets.fromLTRB(m.s20, m.s20, m.s20, m.s20),
          // `Builder` 让内容拿到**弹窗自己的** context（`Navigator.pop(dialogContext)`、
          // `Theme.of` 都对），调用方不必再自己套一层。
          child: Builder(builder: builder),
        ),
      );
    },
  );
}

/// 玻璃底部面板。
///
/// [constraints] 透传给底层 `showModalBottomSheet`：列表型内容（选集抽屉）
/// 需要限制最大高度，否则 `isScrollControlled` 下会撑满整屏。
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  BoxConstraints? constraints,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    constraints: constraints,
    // 同上：sheet 的 Material 底色会盖住玻璃；抓手也由玻璃外壳自己画
    // （主题里的 `dragHandleColor` 画在 sheet 的 Material 上，会和玻璃分层）。
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    builder: (BuildContext sheetContext) {
      final AppTokens tokens = sheetContext.app;
      final AppMetrics m = tokens.metrics;
      // 面板从屏幕底边长出来，下方两角必须是直角；`AppGlass` 只有统一圆角
      // 参数，所以在外层补一层裁剪把下沿切平。裁剪只改裁剪区、不改采样原点，
      // 不是 §11.5 第 1 条禁止的 saveLayer。
      return ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(m.radiusLg)),
        child: AppGlass(
          tier: AppGlassTier.overlay,
          radius: m.radiusLg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _GlassSheetHandle(metrics: m, color: tokens.colors.hairline),
              // `Flexible` 而不是 `Expanded`：内容决定高度，内容要滚动就自己滚。
              Flexible(child: Builder(builder: builder)),
            ],
          ),
        ),
      );
    },
  );
}

/// 玻璃提示条。
///
/// 守卫与 `AppToast` 完全一致（先判 `context.mounted`，再用
/// `ScaffoldMessenger.maybeOf`——页面已销毁 / 没有 Scaffold 时静默丢弃，不崩；
/// 见 `spec/frontend/component-guidelines.md` 的 SnackBar 坑）。不复用
/// `AppToast.show` 的唯一原因是它只接受纯文本、没有「内容构建器」这个缝，
/// 套玻璃必须有缝。
void showGlassToast(BuildContext context, String message) {
  if (!context.mounted) return;
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final AppTokens tokens = context.app;
  final AppMetrics m = tokens.metrics;

  messenger
    // 连续提示替换上一条、不排队（与 `AppToast` 同一行为：连点按钮不该等）。
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        // 底色 / 圆角 / 浮动态 / 文字样式仍来自 `snackBarTheme`，只把填充让给
        // 玻璃：SnackBar 自身的内边距归零，间距由 AppGlass 的 padding 与
        // `snackBarTheme.insetPadding` 共同决定，视觉留白与今天一致。
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        content: AppGlass(
          tier: AppGlassTier.overlay,
          radius: m.radiusSm,
          padding: EdgeInsets.fromLTRB(m.s16, m.s12, m.s16, m.s12),
          child: Text(message),
        ),
      ),
    );
}

/// 面板顶部抓手：`hairline` 胶囊（4 高、32 宽）。
class _GlassSheetHandle extends StatelessWidget {
  const _GlassSheetHandle({required this.metrics, required this.color});

  final AppMetrics metrics;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: metrics.s8, bottom: metrics.s12),
      child: Container(
        width: metrics.s32,
        height: metrics.s4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.all(Radius.circular(metrics.radiusPill)),
        ),
      ),
    );
  }
}
