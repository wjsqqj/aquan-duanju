/// 唯一的定时关闭浮层（design.md §5）：阅读页朗读路径与独立听书页**共用这一个组件**。
///
/// 两条硬规则：
/// - 浮层**自己不建 Timer** —— 剩余时间文本只来自 [SleepTimer.remaining]，
///   由宿主 tick 后重建驱动（两处 UI 各算一遍倒计时必然走样）；
/// - 浮层只驱动组件（[SleepTimer.setMode]），持久化留给宿主的 [onSaved]
///   （统一走 `ReaderListenSettings`，不许另建 prefs 键）。
///
/// [refresh] 是宿主的重建信号（`ReaderSpeechController` 本身就是 `Listenable`；
/// 独立听书页用播放器位置流推的 `ValueNotifier`）。浮层作为独立路由**不会**跟着
/// 页面 setState 重建，所以订阅这个信号把自己刷新；
/// 倒计时的节拍仍来自宿主，
/// 本组件一个 Timer 都不建（§5「由宿主 ListenableBuilder/重建驱动」的落地形态）。
library;

import 'package:flutter/material.dart';

import '../../core/reader/reader_listen_settings.dart';
import '../../core/reader/speech/sleep_timer.dart';

/// 唤出定时浮层。[timer] 是宿主持有的**同一个组件实例**（不是复制品）。
Future<void> showListenSleepSheet(
  BuildContext context, {
  required SleepTimer timer,
  required VoidCallback onSaved,
  Listenable? refresh,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 620),
  builder: (_) =>
      _ListenSleepSheet(timer: timer, onSaved: onSaved, refresh: refresh),
);

class _ListenSleepSheet extends StatefulWidget {
  const _ListenSleepSheet({
    required this.timer,
    required this.onSaved,
    this.refresh,
  });

  final SleepTimer timer;
  final VoidCallback onSaved;
  final Listenable? refresh;

  @override
  State<_ListenSleepSheet> createState() => _ListenSleepSheetState();
}

class _ListenSleepSheetState extends State<_ListenSleepSheet> {
  static const Map<SleepMode, String> _modeLabels = <SleepMode, String>{
    SleepMode.off: '关闭',
    SleepMode.minutes: '定时',
    SleepMode.endOfChapter: '本章播完',
  };

  @override
  void initState() {
    super.initState();
    widget.refresh?.addListener(_onRefresh);
  }

  @override
  void didUpdateWidget(_ListenSleepSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主换信号源时必须解绑旧的，否则回调打在已换掉的实例上。
    if (oldWidget.refresh != widget.refresh) {
      oldWidget.refresh?.removeListener(_onRefresh);
      widget.refresh?.addListener(_onRefresh);
    }
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_onRefresh);
    super.dispose();
  }

  /// 宿主推进（播放位置/切章）→ 重建一次，读到的就是组件当下的 `remaining`。
  void _onRefresh() {
    if (mounted) setState(() {});
  }

  /// 一次选择 = 先改组件、再回调宿主持久化、最后重建本浮层。
  /// 顺序刻意如此：宿主的 onSaved 读到的必须已是新状态。
  void _apply(SleepMode mode, {int? minutes}) {
    widget.timer.setMode(mode, minutes: minutes);
    widget.onSaved();
    setState(() {});
  }

  void _pickMode(SleepMode mode) {
    // 切到「定时」时给一个真实时长：缺省档与设置入口同一个真值。
    _apply(
      mode,
      minutes: mode == SleepMode.minutes
          ? (widget.timer.minutes > 0
              ? widget.timer.minutes
              : ReaderListenSettings.kDefaultSleepMinutes)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timer = widget.timer;
    // 显示文案**只**允许来自 remaining（design §5）；null 表示还没拿到
    // 媒体时间轴基准，如实说「已设定」，不自己编一个倒数。
    final Duration? remaining = timer.remaining;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('定时关闭', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<SleepMode>(
              showSelectedIcon: false,
              segments: [
                for (final entry in _modeLabels.entries)
                  ButtonSegment(value: entry.key, label: Text(entry.value)),
              ],
              selected: <SleepMode>{timer.mode},
              onSelectionChanged: (values) => _pickMode(values.first),
            ),
            if (timer.mode == SleepMode.endOfChapter)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '本章播完后停止，只对这一次生效',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            if (timer.mode == SleepMode.minutes) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final m in kSleepMinutePresets)
                    ChoiceChip(
                      label: Text('$m 分'),
                      selected: timer.minutes == m,
                      onSelected: (_) =>
                          _apply(SleepMode.minutes, minutes: m),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  remaining == null
                      ? '定时已设定，开播后开始计时'
                      : '剩余 ${_mmss(remaining)}（暂停不计时）',
                  key: const ValueKey<String>('sleep-remaining'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _mmss(Duration d) {
    final int s = d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }
}
