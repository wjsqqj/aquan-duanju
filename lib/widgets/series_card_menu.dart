import 'package:flutter/material.dart';

import '../models/models.dart';
import '../store/stores.dart';

/// 列表卡片追剧菜单（A1）：桌面右键 / 移动长按弹出。
///
/// 菜单项与详情页追剧三态一致（detail_screen.dart 的 `_FollowStateMenu`）：
/// 追剧 = watching、想看 = want、已看 = watched，另有「取消追剧」；
/// 已追剧时在当前态那行画勾。动作全部走 [FollowStore]——「我的 › 我的追剧」
/// 是同一份数据源，操作后即时反映（store 通知驱动）。
enum SeriesCardMenuAction { watching, want, watched, remove }

/// 在指针位置弹出追剧菜单并执行所选动作。
///
/// [globalPosition]：`onSecondaryTapUp` / `onLongPressStart` 给出的全局坐标，
/// 桌面 = 右键位置、移动 = 长按位置；两端统一用同一个 `showMenu`。
///
/// 返回用户选中的动作；点菜单外关闭返回 null，不落任何状态。
/// `follows` 由调用方传入（SeriesCard 生产环境取 AppScope，测试直接注入）。
Future<SeriesCardMenuAction?> showSeriesCardMenu(
  BuildContext context, {
  required SeriesSummary item,
  required FollowStore follows,
  required Offset globalPosition,
}) async {
  // 位置与主题先同步取好（不跨 async gap），再加载追剧仓读当前态。
  final Color checkColor = Theme.of(context).colorScheme.primary;
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final RelativeRect position = RelativeRect.fromRect(
    Rect.fromPoints(globalPosition, globalPosition),
    Offset.zero & overlay.size,
  );

  // 追剧仓已加载后，当前态画勾与「是否可取消」判断才可信。
  await follows.ensureLoaded();
  if (!context.mounted) return null;
  final FollowState? current = follows.get(item.id)?.state;

  final SeriesCardMenuAction? action = await showMenu<SeriesCardMenuAction>(
    context: context,
    position: position,
    items: [
      _item(
        '追剧',
        SeriesCardMenuAction.watching,
        current == FollowState.watching,
        checkColor,
      ),
      _item(
        '想看',
        SeriesCardMenuAction.want,
        current == FollowState.want,
        checkColor,
      ),
      _item(
        '已看',
        SeriesCardMenuAction.watched,
        current == FollowState.watched,
        checkColor,
      ),
      const PopupMenuDivider(),
      _item('取消追剧', SeriesCardMenuAction.remove, false, checkColor),
    ],
  );

  switch (action) {
    case SeriesCardMenuAction.watching:
    case SeriesCardMenuAction.want:
    case SeriesCardMenuAction.watched:
      // 没追过的剧先按该状态建立记录（标题为空的异常行静默跳过）。
      await follows.setStateOf(
        seriesId: item.id,
        state: switch (action) {
          SeriesCardMenuAction.want => FollowState.want,
          SeriesCardMenuAction.watched => FollowState.watched,
          _ => FollowState.watching,
        },
        title: item.title,
        coverUrl: item.coverUrl,
        episodeCount: item.episodeCount,
      );
    case SeriesCardMenuAction.remove:
      // 未追过的剧点「取消追剧」是无操作（toggle 会反向变成追剧）。
      if (follows.isFollowing(item.id)) {
        await follows.toggle(
          seriesId: item.id,
          title: item.title,
          coverUrl: item.coverUrl,
          episodeCount: item.episodeCount,
        );
      }
    case null:
      break;
  }
  return action;
}

PopupMenuItem<SeriesCardMenuAction> _item(
  String label,
  SeriesCardMenuAction value,
  bool checked,
  Color checkColor,
) {
  return PopupMenuItem<SeriesCardMenuAction>(
    value: value,
    child: Row(
      children: [
        SizedBox(
          width: 18,
          child: checked
              ? Icon(Icons.check, size: 16, color: checkColor)
              : null,
        ),
        const SizedBox(width: 4),
        Text(label),
      ],
    ),
  );
}
