import 'package:flutter/material.dart';

import '../store/stores.dart';
import '../theme/app_tokens.dart';
import '../theme/player_overlay_theme.dart';
import 'common.dart';
import 'danmaku_block_dialog.dart';
import 'ui/app_gap.dart';

/// 弹幕显示设置面板（播放器「更多 → 弹幕设置」）。
///
/// 四项都写全局设置（`player.danmaku*`），两个播放器共用；面板本身用实色
/// 深色底（[PlayerOverlayTokens.panelFill]）——播放器里弹浅色主题的白底
/// 面板会晃眼，也与 dock 菜单割裂。
Future<void> showDanmakuSettingsSheet(BuildContext context) async {
  final SettingsStore settings = AppScope.read(context).settings;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: PlayerOverlayTokens.panelFill,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: StatefulBuilder(
        builder: (context, setSheetState) {
          void write(void Function() apply) {
            apply();
            setSheetState(() {});
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '弹幕设置',
                  style: PlayerOverlayTokens.stylePrimaryTitleStrong,
                ),
                AppGap.v(AppGapSize.s12),
                _toggleRow(
                  label: '弹幕',
                  subtitle: '关闭后画面不再显示弹幕',
                  value: settings.danmakuEnabled,
                  onChanged: (v) => write(() => settings.danmakuEnabled = v),
                ),
                _choiceRow<int>(
                  label: '显示区域',
                  subtitle: '只出现在选定区域，不挡主体',
                  value: settings.danmakuArea,
                  options: const <int, String>{
                    25: '顶部',
                    50: '半屏',
                    100: '全屏',
                  },
                  onPick: (v) => write(() => settings.danmakuArea = v),
                ),
                _choiceRow<int>(
                  label: '显示行数',
                  subtitle: '区域内最多滚动几行',
                  value: settings.danmakuRows,
                  options: const <int, String>{
                    1: '1 行',
                    2: '2 行',
                    3: '3 行',
                    4: '4 行',
                    6: '6 行',
                    8: '8 行',
                  },
                  onPick: (v) => write(() => settings.danmakuRows = v),
                ),
                _choiceRow<int>(
                  label: '滚动速度',
                  value: settings.danmakuSpeedMs,
                  options: const <int, String>{
                    5000: '快',
                    8000: '标准',
                    12000: '慢',
                    16000: '很慢',
                  },
                  onPick: (v) => write(() => settings.danmakuSpeedMs = v),
                ),
                _choiceRow<int>(
                  label: '字号',
                  value: settings.danmakuFontSize,
                  options: const <int, String>{
                    14: '小',
                    16: '标准',
                    20: '大',
                    24: '特大',
                  },
                  onPick: (v) => write(() => settings.danmakuFontSize = v),
                ),
                _choiceRow<int>(
                  label: '不透明度',
                  value: settings.danmakuOpacity,
                  options: const <int, String>{
                    60: '淡',
                    80: '中',
                    100: '实',
                  },
                  onPick: (v) => write(() => settings.danmakuOpacity = v),
                ),
                _toggleRow(
                  label: '描边',
                  subtitle: '浅色画面下保持文字可读',
                  value: settings.danmakuStroke,
                  onChanged: (v) => write(() => settings.danmakuStroke = v),
                ),
                _toggleRow(
                  label: '同句合并',
                  subtitle: '20 秒内相同的「+1」只出现一次',
                  value: settings.danmakuMergeSame,
                  onChanged: (v) => write(() => settings.danmakuMergeSame = v),
                ),
                const Divider(height: 28, color: Color(0x33FFFFFF)),
                TextButton.icon(
                  onPressed: () => showDanmakuBlockDialog(context),
                  icon: const Icon(Icons.filter_alt_off_outlined,
                      color: PlayerOverlayTokens.textPrimary),
                  label: const Text(
                    '弹幕屏蔽词',
                    style: PlayerOverlayTokens.stylePrimaryBody,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// 一行「标签 + 选项胶囊」。
Widget _choiceRow<T>({
  required String label,
  required T value,
  required Map<T, String> options,
  required ValueChanged<T> onPick,
  String? subtitle,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: PlayerOverlayTokens.stylePrimaryLabel),
            if (subtitle != null) ...[
              AppGap.h(AppGapSize.s8),
              Expanded(
                child: Text(
                  subtitle,
                  style: PlayerOverlayTokens.styleTertiaryCaption,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        AppGap.v(AppGapSize.s8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in options.entries)
              _Pill(
                label: entry.value,
                selected: entry.key == value,
                onTap: () => onPick(entry.key),
              ),
          ],
        ),
      ],
    ),
  );
}

/// 一行「标签 + 说明 + 开关」。
///
/// 不用 `SwitchListTile`：它的默认配色在播放器深色实底上会被主题带成浅色，
/// 且左右留白与 [_choiceRow] 对不齐。
Widget _toggleRow({
  required String label,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: PlayerOverlayTokens.stylePrimaryLabel),
              AppGap.v(AppGapSize.s2),
              Text(
                subtitle,
                style: PlayerOverlayTokens.styleTertiaryCaption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        AppGap.h(AppGapSize.s12),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: PlayerOverlayTokens.textPrimary,
          activeTrackColor: PlayerOverlayTokens.accent,
        ),
      ],
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color brand = context.app.colors.brand;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? brand.withValues(alpha: 0.18)
              : PlayerOverlayTokens.panelHover,
          borderRadius: BorderRadius.all(
            Radius.circular(PlayerOverlayTokens.radiusSm),
          ),
          border: Border.all(
            color: selected ? brand : const Color(0x33FFFFFF),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: PlayerOverlayTokens.stylePrimaryLabel.copyWith(
            color: selected ? brand : PlayerOverlayTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}
