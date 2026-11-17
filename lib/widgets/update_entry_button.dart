import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../update/update_flow.dart';
import '../update/update_service.dart';
import 'ui/app_icons.dart';

/// 发现页顶栏的更新入口：有新版本 / 正在下载 / 待安装时才占位。
///
/// 只在 `UpdateService` 有可执行动作时出现，避免常驻图标变成噪音；
/// 点击复用 [updateInteractive]，弹窗里已有「立即更新 / 跳过此版本 / 稍后」。
class UpdateEntryButton extends StatelessWidget {
  const UpdateEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateService.instance,
      builder: (context, _) {
        final service = UpdateService.instance;
        final downloading = service.isDownloading;
        if (!service.hasUpdate && !downloading && !service.updateReady) {
          return const SizedBox.shrink();
        }
        final IconData icon = downloading
            ? AppIcons.downloading
            : service.updateReady
                ? AppIcons.downloaded
                : AppIcons.download;
        final String tooltip = downloading
            ? '正在下载更新 v${service.latestVersion}'
            : service.updateReady
                ? '更新已下载，点按安装'
                : '发现新版本 v${service.latestVersion}，点按更新';
        return IconButton(
          tooltip: tooltip,
          onPressed: () => updateInteractive(context),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon),
              // 角标只在「有更新但还没开始下载」时出现：正在下载/已下载已经有
              // 自己的图标语义，再叠个点会显得像出错。
              if (service.hasUpdate && !downloading && !service.updateReady)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: context.app.colors.danger,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: context.app.colors.surface1,
                        width: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
