import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'update_errors.dart';
import 'update_service.dart';

/// 有新版本时的交互入口：Windows/Android 且带安装包时给「一键更新」
/// （下载成功后静默安装 / 调起系统安装器）；其它平台跳发布页。
///
/// 强制更新（`update.json` 的 `force` / `minSupportedVersion`）时弹窗不可取消，
/// 也不提供「跳过此版本」。
Future<void> updateInteractive(BuildContext context) async {
  final service = UpdateService.instance;
  if (!service.canInstallInApp) {
    await service.openReleasePage();
    return;
  }
  final isAndroid = Platform.isAndroid;
  final mandatory = service.mandatory;
  // 异步间隙前取好引用，避免 BuildContext 跨 await。
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);

  final action = await showDialog<String>(
    context: context,
    barrierDismissible: !mandatory,
    builder: (dialogContext) => PopScope(
      canPop: !mandatory,
      child: AlertDialog(
        title: Text(mandatory
            ? '必须更新到 v${service.latestVersion}'
            : '发现新版本 v${service.latestVersion}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isAndroid
                ? '一键更新会下载安装包并调起系统安装器；'
                    '首次安装需允许「安装未知应用」。'
                : '一键更新会下载安装包并自动安装，安装过程中应用会关闭，'
                    '完成后会自动重新打开。'),
            const SizedBox(height: 10),
            Text(
              '安装包校验：${service.integrityLabel}',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            Text(
              '更新来源：${service.sourceLabel ?? '官方'}',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            if (mandatory) ...[
              const SizedBox(height: 10),
              Text(
                '当前版本已不再受支持，需要更新后才能继续使用。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          if (!mandatory)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'browser'),
              child: const Text('浏览器打开'),
            ),
          if (!mandatory)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'skip'),
              child: const Text('跳过此版本'),
            ),
          if (!mandatory)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('稍后'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'install'),
            child: const Text('立即更新'),
          ),
        ],
      ),
    ),
  );

  switch (action) {
    case 'browser':
      await service.openReleasePage();
      return;
    case 'skip':
      await service.skipCurrentVersion();
      return;
    case 'install':
      break;
    default:
      return;
  }

  if (!context.mounted) return;
  // 进度框不 await：下载成功后 Windows 直接退出；Android 在调起安装器后关闭。
  unawaited(showDialog<void>(
    useRootNavigator: true,
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('正在下载 v${service.latestVersion}'),
        content: ListenableBuilder(
          listenable: service,
          builder: (context, _) => ValueListenableBuilder<double?>(
            valueListenable: service.downloadProgress,
            builder: (context, progress, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 10),
                Text(progress == null
                    ? '准备下载…'
                    : '${(progress * 100).toStringAsFixed(0)}%'),
                if (service.downloadSourceLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '下载源：${service.downloadSourceLabel}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  ));

  try {
    await service.downloadAndInstall();
  } catch (error) {
    navigator.pop();
    if (!context.mounted) return;
    await _showUpdateFailure(context, messenger, error);
    return;
  }

  navigator.pop();
  if (!isAndroid) return;

  // 系统安装器的结果会异步回来：取消安装 / 签名冲突要能解释清楚，
  // 拿不到结果（多数机型）就当作已交给系统处理，不报错。
  final failure = await service.waitInstallOutcome(const Duration(seconds: 90));
  if (failure == null || !context.mounted) return;
  await _showUpdateFailure(context, messenger, failure);
}

/// 按失败类型给不同形态：用户取消用轻提示，其余给可操作弹窗。
Future<void> _showUpdateFailure(
  BuildContext context,
  ScaffoldMessengerState messenger,
  Object error,
) async {
  final failure = error is UpdateInstallException ? error : null;
  final kind = failure?.kind;
  final message = failure?.message ?? '更新失败：$error';

  if (kind == UpdateFailureKind.userCancelled) {
    if (messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('更新未完成'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            UpdateService.instance.openReleasePage();
          },
          child: const Text('去发布页'),
        ),
      ],
    ),
  );
}
