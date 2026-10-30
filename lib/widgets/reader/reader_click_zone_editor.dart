import 'package:flutter/material.dart';

import '../../core/reader/reader_click_action.dart';
import '../../core/reader/reader_settings.dart';
import '../../store/stores.dart';

/// 九宫格点击区域编辑器：3×3 预览 + 逐格改动作 + 边缘内缩 / 音量键开关。
class ReaderClickZoneEditor extends StatelessWidget {
  const ReaderClickZoneEditor({super.key, required this.store});

  final ReaderSettingsStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final settings = store.value;
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('点击区域', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    TextButton(
                      onPressed: () => store.update(
                        settings.copyWith(
                          clickActions: kDefaultClickActions,
                          zoneLayout: const ClickZoneLayout(),
                        ),
                      ),
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
                Text(
                  '点格子改成想要的动。左列默认上一页，正中默认呼出菜单，右列默认下一页。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 14),
                _ZoneGrid(settings: settings, store: store),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Text('边缘内缩'),
                    Expanded(
                      child: Slider(
                        value: settings.zoneLayout.edgeInset,
                        min: 0,
                        max: 64,
                        divisions: 16,
                        label: '${settings.zoneLayout.edgeInset.round()} px',
                        onChanged: (v) => store.update(
                          settings.copyWith(
                            zoneLayout:
                                settings.zoneLayout.copyWith(edgeInset: v),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${settings.zoneLayout.edgeInset.round()}',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
                Text(
                  '左右两侧内缩的像素：内缩区里的点击算「正中」，用来避开系统返回手势。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('手势左右滑动翻页'),
                  subtitle: const Text('翻页模式下生效；关闭后只能点按或按键翻页'),
                  value: settings.swipeEnabled,
                  onChanged: (v) =>
                      store.update(settings.copyWith(swipeEnabled: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('音量键翻页'),
                  subtitle: const Text('桌面端与外接键盘生效；安卓上系统仍会调音量'),
                  value: settings.volumeKeyPage,
                  onChanged: (v) =>
                      store.update(settings.copyWith(volumeKeyPage: v)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ZoneGrid extends StatelessWidget {
  const _ZoneGrid({required this.settings, required this.store});

  final ReaderSettings settings;
  final ReaderSettingsStore store;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final layout = settings.zoneLayout;
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final rects = layout.rects(size);
          return Stack(
            children: [
              for (var i = 0; i < 9; i++)
                Positioned(
                  left: rects[i].left,
                  top: rects[i].top,
                  width: rects[i].width,
                  height: rects[i].height,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Material(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _pickAction(context, i),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                kClickZoneLabels[i],
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.outline,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                settings.actionAt(i).label,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickAction(BuildContext context, int slot) async {
    final current = settings.actionAt(slot);
    final picked = await showModalBottomSheet<ReaderClickAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '${kClickZoneLabels[slot]} 的动作',
                style: Theme.of(sheetContext).textTheme.titleSmall,
              ),
            ),
            for (final action in ReaderClickAction.values)
              ListTile(
                enabled: action.available,
                leading: Icon(
                  _iconFor(action),
                  color: action.available
                      ? null
                      : Theme.of(sheetContext).disabledColor,
                ),
                title: Text(action.label),
                subtitle: action.available
                    ? null
                    : const Text('暂未支持，选中会提示'),
                trailing: action == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(sheetContext).pop(action),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final next = List<ReaderClickAction>.of(settings.clickActions);
    next[slot] = picked;
    await store.update(settings.copyWith(clickActions: next));
  }

  IconData _iconFor(ReaderClickAction action) => switch (action) {
        ReaderClickAction.none => Icons.block,
        ReaderClickAction.menu => Icons.menu,
        ReaderClickAction.nextPage => Icons.keyboard_arrow_right,
        ReaderClickAction.prevPage => Icons.keyboard_arrow_left,
        ReaderClickAction.nextChapter => Icons.skip_next,
        ReaderClickAction.prevChapter => Icons.skip_previous,
        ReaderClickAction.prevParagraph => Icons.arrow_upward,
        ReaderClickAction.nextParagraph => Icons.arrow_downward,
        ReaderClickAction.addBookmark => Icons.bookmark_add_outlined,
        ReaderClickAction.editContent => Icons.edit_outlined,
        ReaderClickAction.toggleReplace => Icons.find_replace,
        ReaderClickAction.directory => Icons.list_alt,
        ReaderClickAction.searchContent => Icons.search,
        ReaderClickAction.syncProgress => Icons.sync,
        ReaderClickAction.toggleSpeech => Icons.headset,
      };
}
