import 'package:flutter/material.dart';

/// 统一提示条：`SnackBar` 的两处固定写法收敛在这里。
///
/// 为什么必须有这一层（`spec/frontend/component-guidelines.md` 的既有坑）：
/// 页面被 pop 之后，未完成的异步任务回调里拿到的 `context` 已经 deactivate，
/// `ScaffoldMessenger.of(context)` 会直接抛断言。所以这里统一：
/// 1. 先判 `context.mounted`；
/// 2. 用 `ScaffoldMessenger.maybeOf`（没有 Scaffold 时静默丢弃，不崩）。
///
/// 视觉不在这里定义：底色 / 文字 / 圆角 / 浮动行为全部来自 `snackBarTheme`
/// （`AppTheme` 已配置），改动只需改主题。连续提示会**替换**上一条，
/// 而不是排队 —— 连点几下按钮时排队会让人等上十几秒。
class AppToast {
  const AppToast._();

  /// 纯文本提示。
  static void show(BuildContext context, String message) {
    _messengerOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 带一个动作按钮的提示（「撤销」/「查看」/「重试」）。
  static void showAction(
    BuildContext context,
    String message,
    String actionLabel,
    VoidCallback onAction,
  ) {
    _messengerOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(label: actionLabel, onPressed: onAction),
        ),
      );
  }

  /// `null` 表示这次提示没有落脚点（页面已销毁 / 没有 Scaffold）。
  static ScaffoldMessengerState? _messengerOf(BuildContext context) {
    if (!context.mounted) return null;
    return ScaffoldMessenger.maybeOf(context);
  }
}
