import 'package:flutter/material.dart';

import '../../core/aqua_error.dart';
import '../../theme/app_tokens.dart';
import '../loading.dart';
import 'app_empty_state.dart';
import 'app_icons.dart';

enum _StatusKind { loading, error, empty }

/// 三态内容容器：加载中 / 错误 / 空。
///
/// 三条硬约束（父任务 D4 与 11-06 的加载态结论）：
/// - **加载中只允许用既有的 [AppLoading]**：全站两种规格（页面级 32/3、
///   行内 20/2）已经定死，这里不新增转圈参数，也不恢复骨架屏。
/// - **错误文案只允许来自 [AquaException.friendlyText]**；非 `AquaException`
///   一律回落「出了点小问题，请稍后再试」，不把 `toString()` 直接甩给用户。
/// - **「立即重置」只在调用方显式传 `onResetDevice` 时出现**：是否
///   `deviceRecoverable()` 由调用方判断，这里不猜（限流类错误重试只会更快
///   耗尽配额，但换设备是有效恢复路径）。
class AppStatusView extends StatelessWidget {
  const AppStatusView._(
    this._kind, {
    super.key,
    this.message,
    this.error,
    this.onRetry,
    this.onResetDevice,
    this.title,
    this.description,
    this.action,
    this.icon,
  });

  /// 加载中：居中 [AppLoading]，可选一行说明。
  const AppStatusView.loading({Key? key, String? message})
      : this._(_StatusKind.loading, key: key, message: message);

  /// 错误态：`friendlyText` + 「重试」+（可选）「立即重置」。
  ///
  /// [message] 只给历史调用点覆盖文案用（`ErrorRetryView` 需要展示原始原因
  /// 以便排查书源 / 网络问题）；新代码不要传，交给 `friendlyText`。
  const AppStatusView.error(
    Object error, {
    Key? key,
    VoidCallback? onRetry,
    VoidCallback? onResetDevice,
    String? message,
  }) : this._(
          _StatusKind.error,
          key: key,
          error: error,
          onRetry: onRetry,
          onResetDevice: onResetDevice,
          message: message,
        );

  /// 空态：直接委托 [AppEmptyState]。
  const AppStatusView.empty({
    Key? key,
    required String title,
    String? description,
    Widget? action,
    IconData? icon,
  }) : this._(
          _StatusKind.empty,
          key: key,
          title: title,
          description: description,
          action: action,
          icon: icon,
        );

  final _StatusKind _kind;
  final String? message;
  final Object? error;
  final VoidCallback? onRetry;
  final VoidCallback? onResetDevice;
  final String? title;
  final String? description;
  final Widget? action;
  final IconData? icon;

  /// 错误文案：`AquaException` 给用户看得懂的中文，其余回落通用文案。
  static String messageOf(Object error) =>
      error is AquaException ? error.friendlyText : '出了点小问题，请稍后再试';

  @override
  Widget build(BuildContext context) {
    switch (_kind) {
      case _StatusKind.loading:
        return _buildLoading(context);
      case _StatusKind.error:
        return _buildError(context);
      case _StatusKind.empty:
        return AppEmptyState(
          title: title!,
          description: description,
          action: action,
          icon: icon,
        );
    }
  }

  Widget _buildLoading(BuildContext context) {
    final AppTokens tokens = context.app;
    final String? text = message;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.metrics.s16,
        children: <Widget>[
          // 页面级转圈：规格写死在 AppLoading 里，不接受任意尺寸。
          const AppLoading(),
          if (text != null)
            Text(
              text,
              textAlign: TextAlign.center,
              style:
                  tokens.caption.copyWith(color: tokens.colors.textSecondary),
            ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final AppTokens tokens = context.app;
    final String text = message ?? messageOf(error!);
    final VoidCallback? retry = onRetry;
    final VoidCallback? reset = onResetDevice;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.metrics.s24,
          vertical: tokens.metrics.s24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: tokens.metrics.s12,
          children: <Widget>[
            Icon(
              AppIcons.error,
              size: tokens.metrics.s48 + tokens.metrics.s8,
              color: tokens.colors.textTertiary,
            ),
            ConstrainedBox(
              // 长文案按行宽换行，不要横着铺满整屏。
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: tokens.body,
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: tokens.metrics.s8,
              runSpacing: tokens.metrics.s4,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: retry,
                  child: const Text('重试'),
                ),
                if (reset != null)
                  TextButton(
                    onPressed: reset,
                    child: const Text('立即重置'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
