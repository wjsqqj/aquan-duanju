import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'update_errors.dart';
import 'update_service.dart';

/// 有新版本时的交互入口：Windows/Android 且带安装包时给「一键更新」。
///
/// 点完「立即更新」只负责**启动后台下载**：不弹阻塞式进度框，用户可以继续
/// 使用应用；进度/速度/就绪状态在「我的」页的更新卡片里展示。下载并校验完成
/// 后按设置自动静默安装（强制更新无视设置），装完由安装器拉起新版本。
Future<void> updateInteractive(BuildContext context) async {
  final service = UpdateService.instance;
  if (!service.canInstallInApp) {
    await service.openReleasePage();
    return;
  }
  final isAndroid = Platform.isAndroid;
  final mandatory = service.mandatory;
  final messenger = ScaffoldMessenger.of(context);

  // 后台任务已经存在：不重复确认，也不重复下载。
  if (service.updateReady) {
    await _installNow(context, service, messenger);
    return;
  }
  if (service.isDownloading) {
    final percent = service.downloadProgress.value;
    messenger.showSnackBar(SnackBar(
      content: Text(percent == null
          ? '正在后台下载更新，可在「我的」页查看进度'
          : '正在后台下载更新（${(percent * 100).toStringAsFixed(0)}%），可在「我的」页查看进度'),
    ));
    return;
  }
  // 上一轮失败：重试直接续传，不再重复确认一次，少一步点击。
  if (service.downloadPhase == UpdateDownloadPhase.failed) {
    unawaited(service.startBackgroundDownload().catchError((Object error) {
      messenger.showSnackBar(SnackBar(content: Text('重试失败：$error')));
    }));
    messenger.showSnackBar(
      const SnackBar(content: Text('正在重试下载更新，可在「我的」页查看进度')),
    );
    return;
  }

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
                ? '更新会在后台下载，完成后调起系统安装器；'
                    '首次安装需允许「安装未知应用」。'
                : '更新会在后台下载，你可以继续使用应用；'
                    '下载完成后自动安装并重启。'),
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

  unawaited(service.startBackgroundDownload().catchError((Object error) {
    messenger.showSnackBar(SnackBar(content: Text('更新启动失败：$error')));
  }));
  messenger.showSnackBar(const SnackBar(
    content: Text('已开始后台下载，可在「我的」页查看进度'),
    duration: Duration(seconds: 3),
  ));
}

/// 已下载完成时的手动安装入口（关闭「自动安装」或在失败后重试）。
Future<void> _installNow(
  BuildContext context,
  UpdateService service,
  ScaffoldMessengerState messenger,
) async {
  try {
    await service.installDownloaded();
  } catch (error) {
    if (!context.mounted) return;
    await _showUpdateFailure(context, messenger, error);
  }
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
