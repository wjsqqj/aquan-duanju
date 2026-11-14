import 'package:flutter/material.dart';

import 'common.dart';
import '../store/stores.dart';

/// 弹幕屏蔽词编辑面板（两个播放器共用）。
///
/// 存储语义与 [SettingsStore.biliDanmakuBlock] 一致：逗号分隔，`re:` 前缀
/// 按正则（非法正则保存不阻断——过滤时会被跳过）。
Future<void> showDanmakuBlockDialog(BuildContext context) async {
  final scope = AppScope.read(context);
  final controller =
      TextEditingController(text: scope.settings.biliDanmakuBlock);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('弹幕屏蔽词'),
      content: TextField(
        controller: controller,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: '逗号分隔；re: 前缀按正则（如 re:广告|剧透）',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: () {
              scope.settings.biliDanmakuBlock = controller.text.trim();
              Navigator.pop(context);
            },
            child: const Text('保存')),
      ],
    ),
  );
}
